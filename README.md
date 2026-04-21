# atlas

a content-addressed, event-sourced file system on beam.

## what it does

atlas chunks your files with fastcdc, hashes each chunk with blake3,
stores them in a local cas, and logs every state change as a typed
event. projections rebuild deterministically from the log. a filesystem
watcher keeps everything live; incremental re-scans are free. identical
content is stored once; editing one byte of a 2 gb file stores ~80 kb of
new data, not 2 gb.

currently its just a single-node kernel — cli only, local filesystem only, no
sync. future scope adds a ui, p2p sync, cloud volumes, unified search,
mobile clients, and capability-scoped ai agents.

## requirements

- elixir 1.17+ / otp 27+
- rust 1.85+ (builds the native nif)

pinned versions in `.tool-versions`.

## quick start

```sh
mix setup
mix atlas.watch ~/pictures        # index + watch, blocks
# in another terminal:
mix atlas.ls
mix atlas.find "vacation"
mix atlas.gc
mix atlas.rebuild_projection
mix test
```

## layout

```
lib/atlas/
  domain/            pure value objects
  store/             content-addressed object store
  log/               append-only event log + pub/sub notifier
  projection/        log → ecto projector
  indexer/           walker + chunker
  watcher/           fsevents / inotify
  locations.ex       manager
  gc.ex              orphan chunk reclamation
  schemas/           ecto schemas
native/atlas_native/ rust nif (blake3 + fastcdc)
priv/repo/migrations ecto migrations
test/                unit + integration
```

## license

tbd.
