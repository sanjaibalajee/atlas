ExUnit.start()

# Tests that require the NIF are tagged `:nif` — exclude them with
# `mix test --exclude nif` if the Rust toolchain is unavailable.
ExUnit.configure(exclude: [skip: true])
