# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Portsnap mirroring code for MidnightBSD, derived from Colin Percival's FreeBSD
`user/cperciva/portsnap-mirror` (see the `$FreeBSD:` tag at `ps-mirror.sh:28`). These
scripts pull a portsnap master's published tree onto a local mirror and republish it
over HTTP. There is no build system, test suite, or dependency manifest — the entire
repo is three POSIX `sh` scripts plus embedded Perl.

## Running and validating

The scripts only run on MidnightBSD: they depend on `/usr/libexec/phttpget`,
`fetch`, `lam`, `sha256`, and (in the documented invocation) `lockf`. They will not run
as-is on Linux, so on a Linux dev box you can only syntax-check and reason about them:

```sh
sh -n ps-mirror.sh          # POSIX sh syntax check (works anywhere)
shellcheck ps-mirror.sh     # if installed; expect noise from the BSD-only tools
```

Real invocation, guarded so concurrent cron runs can't overlap:

```sh
lockf -s -t 0 lockfile sh -e ps-mirror.sh portsnap1.midnightbsd.org /path/to/www
```

Both mirror scripts take exactly two arguments: the upstream portsnap server and the
public web root. A first run against an empty `PUBDIR` self-initializes it (creates
`bp/ f/ s/ t/ tp/`, an empty `latest.ssl`, and a `robots.txt` that disallows everything).

## The three scripts

- **`ps-mirror.sh`** — the version actually deployed for MidnightBSD. Use this one.
- **`pmirror.sh`** — the upstream FreeBSD base. It is byte-identical to `ps-mirror.sh`
  except that `ps-mirror.sh` adds the "Updating indextimes" step (`ps-mirror.sh:329-335`),
  which maintains `${PUBDIR}/indextimes` from the `INDEX` entries in `tl`. When changing
  mirroring logic, apply the change to **both** files so the pair stays a clean diff;
  otherwise future rebases against upstream get much harder.
- **`ps-cron.sh`** — deployment wrapper for cron. Paths are hardcoded to the production
  host (`/local0/ps-mirror/wrkdir`, `/root/efs-fup/ps-mirror.sh`, `/local0/ps-mirror/www`).
  It times the run and touches `/local0/ps-mirror/initialized` when a sync finishes in
  under 60 seconds, i.e. when the mirror was already current; a slower run just logs its
  duration. This file is environment-specific config, not shared logic.

## How a mirror run works

Everything happens in a `mktemp -d` working directory that is removed at the end; the
published tree under `${PUBDIR}` is only mutated by targeted `mv`/`rm` near the end of
each stage.

1. **Early exit.** Fetch `pub.ssl`, `snapshot.ssl`, `latest.ssl`. If `latest.ssl` matches
   the published copy, nothing upstream changed — clean up and exit 0.
2. **Per-category sync.** Each of binary patches (`bp/`), metadata files (`f/`),
   snapshots (`s/`), and tags (`t/`) follows the same pattern: build a sorted `*.wanted`
   list from the upstream index (`bl.gz`, `tl.gz`, `el.gz`), build `*.present` by listing
   the published directory, then `comm -13` to fetch what's missing and `comm -23` to
   delete what's obsolete. Both sides are filtered through
   `grep -E '^[0-9a-f]{64}...'` — this is the sanitization boundary that keeps
   server-supplied strings from reaching `xargs`/`rm`, so keep it on any new list.
   Tags are deliberately never pruned (`ps-mirror.sh:180-184`).
3. **Retention windows.** `LASTSNAP` is the newest timestamp in `bl`; what's kept is
   defined by cutoffs relative to it — 86400s (1 day) for binary patches, files, and
   metadata patches, 691200s (8 days) for metadata files.
4. **Integrity check.** Newly fetched `f/*.gz` are gunzipped and SHA-256'd against their
   own filename; mismatches are deleted so the next run refetches them.
5. **Metadata patch generation** (`ps-mirror.sh:201-320`) — the expensive part. Patches
   the mirror must serve are *generated locally*, not downloaded. Two embedded Perl
   programs do the work: one diffs two sorted metadata files into `-`/`+` lines, and the
   other composes two existing patches (`X→M` and `M→Y`) into `X→Y` when they're already
   published, avoiding a full re-diff. Results over 100000 bytes are discarded rather
   than published.
6. **Publish.** `bl.gz`, `el.gz`, `tl.gz` and the three `.ssl` files are moved into
   `${PUBDIR}` last, so `latest.ssl` only advances after the content it describes is in
   place. Preserve that ordering.

## Conventions

- POSIX `sh` with `#!/bin/sh -e`; hard tabs for indentation.
- The upstream BSD 2-clause header on the mirror scripts is Colin Percival's and must be
  retained. `LICENSE` (BSD 2-clause, MidnightBSD) covers the repo.
- Stage boundaries are announced with `` echo "`date`: ..." `` — cron output is the only
  log, so keep new stages narrated the same way.
- `|| true` after `grep -v "200 OK"` and after `ls`-based list building is intentional:
  it stops empty results from tripping `-e`. Don't remove it as dead code.
