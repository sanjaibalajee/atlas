//! BLAKE3 hashing primitives.

use rustler::{Binary, Env, NewBinary};
use std::io::Read;

const STREAM_BUF: usize = 64 * 1024;

fn finalize_into_binary<'a>(env: Env<'a>, digest: &[u8; 32]) -> Binary<'a> {
    let mut bin = NewBinary::new(env, 32);
    bin.as_mut_slice().copy_from_slice(digest);
    bin.into()
}

/// BLAKE3 hash of an in-memory binary. 32 bytes.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn hash_bytes<'a>(env: Env<'a>, bytes: Binary<'a>) -> Binary<'a> {
    let digest = blake3::hash(bytes.as_slice());
    finalize_into_binary(env, digest.as_bytes())
}

/// BLAKE3 hash of a file, streamed — does not load the whole file into RAM.
#[rustler::nif(schedule = "DirtyIo")]
pub fn hash_file<'a>(env: Env<'a>, path: String) -> Result<Binary<'a>, String> {
    let file = std::fs::File::open(&path).map_err(|e| e.to_string())?;
    let mut reader = std::io::BufReader::with_capacity(STREAM_BUF, file);
    let mut hasher = blake3::Hasher::new();
    let mut buf = [0u8; STREAM_BUF];

    loop {
        let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    let digest = hasher.finalize();
    Ok(finalize_into_binary(env, digest.as_bytes()))
}
