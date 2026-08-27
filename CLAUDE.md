# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Portsnap mirroring code for MidnightBSD, derived from Colin Percival's FreeBSD
`user/cperciva/portsnap-mirror`. The script pulls a portsnap master's published tree
onto a local mirror and republishes it over HTTP. There is no build system or dependency
manifest — the repo is one POSIX `sh` script with embedded Perl, and one shell regression
suite.

## Running and validating

The scripts target MidnightBSD/FreeBSD: they use `/usr/libexec/phttpget`, `fetch`,
`lam`, `sha256`, `bspatch`, `tar`, and (in the documented invocation) `lockf`, so a real
run needs that platform. The test suite, however, stubs the network tools and runs
anywhere:

```sh
sh tests/f2-regression.sh   # full suite; no network, no portsnap server needed
sh -n pmirror.sh            # syntax-only check
```

`tests/f2-regression.sh` builds a fake origin tree and fake `phttpget`/`fetch` in a
temp dir, then runs the mirror script through every case.
Cases include a transfer that fails partway (`FAIL_OBJECT`), an origin that silently
omits a requested object (`OMIT_OBJECT`), invalid origin objects, corrupt published
objects in every served class, symlinked objects, and an unchanged generation with and
without clock skew. There is no way to run a single case from the command line — edit the
`run_case` list at the bottom if you need to narrow it down. Run this suite for any change to the mirroring logic;
it is the only check that exists.

Real invocation, guarded so concurrent cron runs can't overlap:

```sh
lockf -s -t 0 lockfile sh -e pmirror.sh portsnap1.midnightbsd.org /path/to/www
```

The script takes exactly two arguments: the upstream portsnap server and the public web
root. A first run against an empty `PUBDIR` self-initializes it (creates `bp/ f/ s/ t/
tp/`, an empty `latest.ssl`, and a `robots.txt` that disallows everything).

## Main files

- **`pmirror.sh`** — the mirror implementation deployed by MidnightBSD.
- **`tests/f2-regression.sh`** — the isolated regression suite for mirroring behavior.

## How a mirror run works

Everything happens in a `mktemp -d` working directory. Downloads land in `STAGEDIR`, a
mode-0700 `mktemp` directory created *inside* `${PUBDIR}` so that installing a file is an
atomic rename on the same filesystem. Both directories are removed by the
`trap cleanup 0` handler — that trap is why no stage needs its own unwind path.

1. **Control fetch.** `pub.ssl`, `snapshot.ssl`, `latest.ssl`. If `latest.ssl` matches
   the published copy, `LATEST_UNCHANGED=yes` and the run continues in verify-and-repair
   mode: manifests are copied from `${PUBDIR}` instead of refetched, object pruning still
   runs, and only control-file publication is skipped. It does **not** exit
   early — a run against an unchanged generation still repairs missing or corrupt
   objects.
2. **Per-category sync.** Binary patches (`bp/`), metadata files (`f/`), snapshots
   (`s/`), tags (`t/`): build a sorted `*.wanted` list from the upstream index
   (`bl.gz`, `tl.gz`, `el.gz`), list what's present, and derive `*.missing`. Every list
   is filtered through `grep -E '^[0-9a-f]{64}...'` — the sanitization boundary that
   keeps server-supplied strings out of `xargs`/`rm`. Keep it on any new list.
3. **Retention windows.** `LASTSNAP` is the newest timestamp in `bl`; cutoffs are
   relative to it — 86400s (1 day) for binary patches, files, and metadata patches,
   691200s (8 days) for metadata files. Tags are deliberately never pruned.
4. **Fetch, scrub, install, verify.** `fetch_missing_files` checks phttpget's exit status
   separately from its filtered log and confirms each requested file actually landed in
   the staging dir. `f/` and `t/` objects are checked directly against their SHA-256
   filenames. `bp/` files are applied with `bspatch`, `tp/` diffs are applied with the
   portsnap metadata algorithm, and `s/` archives are unpacked and verified against their
   hashed `t/` metadata. Validation operates on private stable copies. Required invalid
   objects stay published until an atomically installed repair has validated; invalid
   unneeded hashed files and tags are then isolated in private staging. Snapshot archives
   additionally reject links, special files, duplicate paths, and oversized archives or
   inner objects.
   The complete retained set is checked again before publication. Keep the protocol
   validators aligned with the portsnap client.
5. **Metadata patch generation** — the expensive part. Patches the
   mirror must serve are *generated locally*, not downloaded. Two embedded Perl programs:
   one diffs two sorted metadata files into `-`/`+` lines, the other composes existing
   `X→M` and `M→Y` patches into `X→Y` to avoid a full re-diff. Results ≥100000 bytes are
   discarded rather than published. Metadata patches are therefore best-effort: every
   retained patch is validated, but an omitted patch over the size threshold is not a
   mirror completeness failure because clients can fetch the full metadata object.
6. **Prune and publish.** Obsolete objects are removed on every run. When the generation
   changed, `bl.gz`, `el.gz`, `tl.gz` and the three `.ssl` files are moved into
   `${PUBDIR}` last, so `latest.ssl` only advances after everything it describes is in
   place. Preserve that ordering.

## Conventions

- POSIX `sh` with `#!/bin/sh -e`; hard tabs for indentation.
- **Never pipe a `phttpget` or `fetch` invocation into `grep -v "200 OK" || true`.** That
  was the original upstream idiom and it discards the transfer's exit status, which is
  how incomplete generations got published. Capture output to a log, check the status,
  then filter the log — see `fetch_missing_files`.
- `|| true` after `ls`-based list building is still intentional: it stops an empty `grep`
  result from tripping `-e`. Don't remove it as dead code.
- The upstream BSD 2-clause header on the mirror scripts is Colin Percival's and must be
  retained. `LICENSE` (BSD 2-clause, MidnightBSD) covers the repo.
- Stage boundaries are announced with `` echo "`date`: ..." `` — cron output is the only
  log, so narrate new stages the same way. Errors go to stderr and abort.
