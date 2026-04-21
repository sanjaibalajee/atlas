//! FastCDC content-defined chunking + per-chunk BLAKE3 hashing.
//!
//! Returns Elixir `%Atlas.Domain.Chunk{}` structs (offset, length, hash).
//! The struct layout is mirrored in `lib/atlas/domain/chunk.ex`.
//!
//! Three NIFs:
//!
//!   * `chunk_bytes/1`           — chunk an in-memory binary (used in tests)
//!   * `chunk_file/1`            — chunk a file, whole-file read into RAM
//!   * `chunk_and_store_file/2`  — M1.3 hot path: stream a file through
//!                                  FastCDC, write each chunk directly into
//!                                  the CAS at `<root>/<shard>/<rest>`,
//!                                  return only the metadata
//!
//! The third variant is the indexer's production path. It never materializes
//! the whole file in RAM (memory is bounded by MAX_CHUNK) and it avoids
//! Phase 0's double read + double hash.

use fastcdc::v2020::{FastCDC, StreamCDC};
use rustler::{Binary, Env, NewBinary, NifStruct};
use std::fs::{self, File};
use std::io::{BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

// FastCDC tuning. Phase 0 defaults — revisit once we have real workloads.
const MIN_CHUNK: u32 = 8 * 1024; //   8 KB
const AVG_CHUNK: u32 = 64 * 1024; //  64 KB
const MAX_CHUNK: u32 = 256 * 1024; // 256 KB

// Read-ahead buffer for StreamCDC. The chunker internally buffers up to
// MAX_CHUNK at any moment; this just controls syscall size.
const READ_BUF: usize = 64 * 1024;

// Monotonic counter for temp-file names so concurrent writers can't collide
// even on the same PID.
static TMP_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(NifStruct)]
#[module = "Atlas.Domain.Chunk"]
pub struct Chunk<'a> {
    pub offset: u64,
    pub length: u64,
    pub hash: Binary<'a>,
}

fn chunk_slice<'a>(env: Env<'a>, data: &[u8]) -> Vec<Chunk<'a>> {
    FastCDC::new(data, MIN_CHUNK, AVG_CHUNK, MAX_CHUNK)
        .into_iter()
        .map(|c| {
            let end = c.offset + c.length;
            let digest = blake3::hash(&data[c.offset..end]);

            let mut hash_bin = NewBinary::new(env, 32);
            hash_bin.as_mut_slice().copy_from_slice(digest.as_bytes());

            Chunk {
                offset: c.offset as u64,
                length: c.length as u64,
                hash: hash_bin.into(),
            }
        })
        .collect()
}

/// Chunk an in-memory binary and hash each chunk.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn chunk_bytes<'a>(env: Env<'a>, bytes: Binary<'a>) -> Vec<Chunk<'a>> {
    chunk_slice(env, bytes.as_slice())
}

/// Chunk a file by path. Reads the whole file into RAM first — use
/// `chunk_and_store_file` for large files.
#[rustler::nif(schedule = "DirtyIo")]
pub fn chunk_file<'a>(env: Env<'a>, path: String) -> Result<Vec<Chunk<'a>>, String> {
    let data = std::fs::read(&path).map_err(|e| e.to_string())?;
    Ok(chunk_slice(env, &data))
}

/// Stream `path` through FastCDC, write each chunk atomically into the CAS
/// rooted at `store_root`, return only the metadata.
///
/// Layout: `<store_root>/<first-2-hex-chars>/<remaining-62-chars>`.
/// Must match `Atlas.Store.LocalFs.chunk_path/1` — changing one requires
/// changing the other.
///
/// Idempotent: if the target file already exists we skip the write.
/// Atomic: writes go to a temp name in the shard dir and are renamed into
/// place, so a reader never observes a partial chunk file.
#[rustler::nif(schedule = "DirtyIo")]
pub fn chunk_and_store_file<'a>(
    env: Env<'a>,
    path: String,
    store_root: String,
) -> Result<Vec<Chunk<'a>>, String> {
    let file = File::open(&path).map_err(|e| format!("open {}: {}", path, e))?;
    let reader = BufReader::with_capacity(READ_BUF, file);
    let chunker = StreamCDC::new(reader, MIN_CHUNK, AVG_CHUNK, MAX_CHUNK);

    let root = PathBuf::from(store_root);
    let mut chunks = Vec::new();

    for result in chunker {
        let cd = result.map_err(|e| format!("stream_cdc: {}", e))?;
        let digest = blake3::hash(&cd.data);
        let hash_bytes = digest.as_bytes();

        write_chunk_to_cas(&root, hash_bytes, &cd.data)?;

        let mut hash_bin = NewBinary::new(env, 32);
        hash_bin.as_mut_slice().copy_from_slice(hash_bytes);

        chunks.push(Chunk {
            offset: cd.offset,
            length: cd.length as u64,
            hash: hash_bin.into(),
        });
    }

    Ok(chunks)
}

fn write_chunk_to_cas(root: &Path, hash: &[u8; 32], data: &[u8]) -> Result<(), String> {
    let hex = hex_lower(hash);
    let shard_dir = root.join(&hex[0..2]);
    let final_path = shard_dir.join(&hex[2..]);

    if final_path.exists() {
        return Ok(());
    }

    fs::create_dir_all(&shard_dir).map_err(|e| format!("mkdir {:?}: {}", shard_dir, e))?;

    let counter = TMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    let tmp_name = format!("{}.tmp.{}.{}", &hex[2..], std::process::id(), counter);
    let tmp_path = shard_dir.join(&tmp_name);

    {
        let mut f = File::create(&tmp_path)
            .map_err(|e| format!("create {:?}: {}", tmp_path, e))?;
        f.write_all(data).map_err(|e| format!("write {:?}: {}", tmp_path, e))?;
        // No per-chunk fsync: Phase 1 matches Phase 0's durability story.
        // M1.8+ will revisit once we care about sudden-power-loss semantics.
    }

    fs::rename(&tmp_path, &final_path).map_err(|e| {
        // Clean up the temp file if rename fails.
        let _ = fs::remove_file(&tmp_path);
        format!("rename {:?} -> {:?}: {}", tmp_path, final_path, e)
    })?;

    Ok(())
}

fn hex_lower(bytes: &[u8]) -> String {
    const TABLE: &[u8; 16] = b"0123456789abcdef";
    let mut out = Vec::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(TABLE[(b >> 4) as usize]);
        out.push(TABLE[(b & 0x0f) as usize]);
    }
    // SAFETY: only ASCII hex chars pushed.
    unsafe { String::from_utf8_unchecked(out) }
}
