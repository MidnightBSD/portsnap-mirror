# portsnap-mirror

portsnap mirroring code based on Colin's FreeBSD version, adapted for MidnightBSD.

These scripts keep a local copy of a portsnap master's published tree and republish it
over HTTP, so `portsnap fetch` clients can be served from your own host.

## Requirements

MidnightBSD or FreeBSD. The scripts use `/usr/libexec/phttpget`, `fetch`, `lam`,
`sha256`, `bspatch`, `tar`, `perl`, and `lockf`, so they will not run unmodified on
other systems.

Budget roughly **1GB of disk** and **5GB/month of bandwidth** per mirror. Because
portsnap's graceful-failure handling requires a mirror to carry large files it may never
serve, running a mirror is only worthwhile if you expect a large number of clients to
use it — see the notes at the top of `pmirror.sh`.

## Usage

`pmirror.sh` takes the upstream portsnap server and the public web root:

```sh
/usr/local/portsnap-mirror/pmirror.sh portsnap1.midnightbsd.org /home/portsnap/htmldocs/
```

The first run against an empty web root sets it up: it creates the `bp/`, `f/`, `s/`,
`t/`, and `tp/` subdirectories, an empty `latest.ssl`, and a `robots.txt` that disallows
crawling. Point your web server's document root at that directory.

Runs are incremental, and every run also repairs. When the upstream `latest.ssl` is
unchanged the script reuses the manifests it already published rather than refetching
them, but it still confirms that every object the mirror is required to serve is present
and valid, and prunes objects outside the signed retention set. Content-addressed files
are checked against their SHA-256 names, binary and
metadata patches are applied and checked against their target hashes, and snapshot
archives are unpacked and verified against their hashed metadata. Required corrupt
objects are replaced atomically after their repairs validate; invalid unneeded hashed
files and tags are isolated in private staging and discarded when the run completes.
Anything already valid is left alone. Binary-patch source objects are retained while
their patches are retained so later scrubs remain self-contained.

Downloads land in a private staging directory on the same filesystem and are only moved
into the web root once verified, and the manifests and `.ssl` files are published last.
A failed transfer aborts the run, so `latest.ssl` never advertises a generation the
mirror cannot fully serve.
Snapshot validation also rejects links, special files, duplicate members, and archives
whose compressed, declared expanded, or per-object expanded size exceeds the safety
limits in `pmirror.sh`.

### From cron

Wrap the invocation in `lockf` so a slow run cannot overlap the next one:

```sh
0 * * * * lockf -s -t 0 /var/run/pmirror.lock \
	/usr/local/portsnap-mirror/pmirror.sh portsnap1.midnightbsd.org /home/portsnap/htmldocs/
```

Each stage is announced with a timestamp on stdout, so cron mail is a usable log. A run
against an unchanged generation says it is verifying mirror contents.

## Cleaning a primary rsync web root

Do not delete Portsnap objects based only on filesystem modification time. An immutable
content-addressed object can remain referenced by a current manifest long after its
original upload time.

`portsnap-clean.sh` is intended for the primary webserver which receives a published
tree via rsync. It reads only the local `bl.gz`, `tl.gz`, and `el.gz` manifests; it does
not contact the private builder. By default it is a dry run:

```sh
/usr/local/portsnap-mirror/portsnap-clean.sh /home/portsnap/htmldocs/
```

Apply mode records when each object first becomes unreferenced. An object must remain
unreferenced for 45 days before it is moved outside the web root into
`/home/portsnap/.portsnap-clean/quarantine/`. Quarantine batches are retained for another
30 days before deletion:

```sh
lockf -s -t 0 /home/portsnap/.portsnap-publish.lock \
	/usr/local/portsnap-mirror/portsnap-clean.sh --apply /home/portsnap/htmldocs/
```

Use the same lock around the webserver-side rsync operation when possible. The script
also compares stable copies of all manifests and control files before changing anything,
rejects malformed or oversized manifests, ignores unexpected filenames, and never
manages top-level control files. The grace period protects newly rsynced objects which
arrive before their manifests and old objects referenced by cached manifests. Run it as
the dedicated account which owns the web root; it refuses publication and state
directories owned by another account or writable by a group or other users. The primary
build's `bp/`, `f/`, `s/`, and `t/` directories are required; `tp/` is cleaned when
present.

## Mirror script

`pmirror.sh` is what mirror operators run.

## Tests

```sh
sh tests/f2-regression.sh
sh tests/cleanup-regression.sh
```

The suite stubs out `phttpget` and `fetch` against a fake origin tree, so it needs no
network and no portsnap server. It covers the failure
modes that matter: a transfer that dies partway through, an origin that silently omits a
requested object, invalid content from the origin, corrupt retained objects in every
served object class, and symlinked publication entries.

## License

BSD 2-clause. The mirroring scripts carry Colin Percival's original copyright; see
`LICENSE` for the MidnightBSD terms covering this repository.
