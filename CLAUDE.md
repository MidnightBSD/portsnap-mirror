# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Portsnap mirroring code for MidnightBSD, derived from Colin Percival's FreeBSD
`user/cperciva/portsnap-mirror` (see the `$FreeBSD:` tag at `ps-mirror.sh:28`). These
scripts pull a portsnap master's published tree onto a local mirror and republish it
over HTTP. There is no build system or dependency manifest — the repo is two POSIX `sh`
scripts plus embedded Perl, and one shell regression suite.

## Running and validating

The scripts target MidnightBSD/FreeBSD: they use `/usr/libexec/phttpget`, `fetch`,
`lam`, `sha256`, and (in the documented invocation) `lockf`, so a real run needs that
platform. The test suite, however, stubs the network tools and runs anywhere:

```sh
sh tests/f2-regression.sh   # full suite; no network, no portsnap server needed
sh -n pmirror.sh            # syntax-only check
```

`tests/f2-regression.sh` builds a fake origin tree and fake `phttpget`/`fetch` in a
temp dir, then runs **both** scripts through every case (`tests/f2-regression.sh:214`).
Cases: a transfer that fails partway (`FAIL_OBJECT`), an origin that silently omits a
requested object (`OMIT_OBJECT`), an origin serving an object under the wrong hash, a
corrupt `f/` or `t/` object already published, a symlinked object, and an unchanged
generation with and without clock skew. The first four must fail the run; the rest must
succeed. There is no way to run a single case from the command line — edit the
`run_case` list at the bottom if you need to narrow it down. Run this suite for any change to the mirroring logic;
it is the only check that exists.

Real invocation, guarded so concurrent cron runs can't overlap:

```sh
lockf -s -t 0 lockfile sh -e pmirror.sh portsnap1.midnightbsd.org /path/to/www
```

Both scripts take exactly two arguments: the upstream portsnap server and the public web
root. A first run against an empty `PUBDIR` self-initializes it (creates `bp/ f/ s/ t/
tp/`, an empty `latest.ssl`, and a `robots.txt` that disallows everything).

## The two scripts

- **`pmirror.sh`** — what mirror operators run. This is the one to reach for by default.
- **`ps-mirror.sh`** — identical except for the "Updating indextimes" step near the end,
  which accumulates `${PUBDIR}/indextimes` (INDEX hash → build time) from the `INDEX`
  entries in `tl`. Nothing in portsnap fetches that file; it is read off local disk by
  `www-logprocess.sh` in cperciva's `efs-fup` to compute how much update data clients
  pulled, by version. Only useful on a host that also processes its own web logs.

When changing mirroring logic, apply the change to **both** files — `indextimes` is the
only intended difference, and the suite runs both, so a divergence shows up as a test
failure rather than silently.

Note the `indextimes` step reads `${PUBDIR}/indextimes` unconditionally via `join`, and
nothing creates it — not even the empty-web-root setup block — so `ps-mirror.sh` aborts
on a web root that has never had one. The test suite works around this by pre-creating
the file (`tests/f2-regression.sh:115`). Guarding the step on the file's existence would
both fix that and let the two scripts collapse into one.

## How a mirror run works

Everything happens in a `mktemp -d` working directory. Downloads land in `STAGEDIR`, a
mode-0700 `mktemp` directory created *inside* `${PUBDIR}` (`pmirror.sh:196-198`) so that
installing a file is an atomic rename on the same filesystem. Both directories are
removed by the `trap cleanup 0` handler (`pmirror.sh:70-81`) — that trap is why no stage
needs its own unwind path.

1. **Control fetch.** `pub.ssl`, `snapshot.ssl`, `latest.ssl`. If `latest.ssl` matches
   the published copy, `LATEST_UNCHANGED=yes` and the run continues in verify-and-repair
   mode: manifests are copied from `${PUBDIR}` instead of refetched, and the pruning and
   publishing steps at the end are skipped (`pmirror.sh:453`). It does **not** exit
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
4. **Fetch, install, verify.** `fetch_missing_files` checks phttpget's exit status
   separately from its filtered log and confirms each requested file actually landed in
   the staging dir. `validate_content_addressed_files` gunzips (`f/`) or reads (`t/`)
   each object and compares SHA-256 against its own filename, rejecting symlinks;
   invalid objects are left out of the valid list so they get refetched. After
   `install_staged_files`, `verify_required_files` plus a final validation pass must
   account for every wanted object — `cmp -s f.wanted f.final.valid || exit 1`. The run
   fails closed rather than publishing an incomplete generation.
5. **Metadata patch generation** (`pmirror.sh:333-451`) — the expensive part. Patches the
   mirror must serve are *generated locally*, not downloaded. Two embedded Perl programs:
   one diffs two sorted metadata files into `-`/`+` lines, the other composes existing
   `X→M` and `M→Y` patches into `X→Y` to avoid a full re-diff. Results ≥100000 bytes are
   discarded rather than published.
6. **Prune and publish** (skipped when unchanged). Obsolete objects are removed, then
   `bl.gz`, `el.gz`, `tl.gz` and the three `.ssl` files are moved into `${PUBDIR}` last,
   so `latest.ssl` only advances after everything it describes is in place. Preserve
   that ordering.

## Conventions

- POSIX `sh` with `#!/bin/sh -e`; hard tabs for indentation.
- **Never pipe a `phttpget` or `fetch` invocation into `grep -v "200 OK" || true`.** That
  was the original upstream idiom and it discards the transfer's exit status, which is
  how incomplete generations got published. Capture output to a log, check the status,
  then filter the log — see `fetch_missing_files` (`pmirror.sh:90-116`).
- `|| true` after `ls`-based list building is still intentional: it stops an empty `grep`
  result from tripping `-e`. Don't remove it as dead code.
- The upstream BSD 2-clause header on the mirror scripts is Colin Percival's and must be
  retained. `LICENSE` (BSD 2-clause, MidnightBSD) covers the repo.
- Stage boundaries are announced with `` echo "`date`: ..." `` — cron output is the only
  log, so narrate new stages the same way. Errors go to stderr and abort.
