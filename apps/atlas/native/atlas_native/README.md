# atlas_native

Rust NIF backing `Atlas.Native`.

Exports:

| NIF            | Elixir signature                                    | Scheduler  |
|----------------|-----------------------------------------------------|------------|
| `hash_bytes`   | `(binary) -> binary`                                | DirtyCpu   |
| `hash_file`    | `(String.t) -> {:ok, binary} \| {:error, String.t}` | DirtyIo    |
| `chunk_bytes`  | `(binary) -> [Atlas.Domain.Chunk.t]`                | DirtyCpu   |
| `chunk_file`   | `(String.t) -> {:ok, list} \| {:error, String.t}`   | DirtyIo    |

Built automatically by `mix compile` via the Rustler mix compiler configured
in the parent `mix.exs`. You should never need to invoke `cargo` directly.

## Tuning

FastCDC bounds are hard-coded in `src/chunking.rs`:

- min: 8 KB
- avg: 64 KB
- max: 256 KB

These are reasonable defaults for mixed media workloads. We'll make them
runtime-configurable once Phase 1 profiling gives us data.
