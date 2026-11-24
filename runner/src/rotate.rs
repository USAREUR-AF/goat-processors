//! An append-only file of JSON lines with an optional size limit: the
//! output file, the record and the audit log.
//!
//! When a line would take the file past `max_bytes`, the file is renamed to
//! `<path>.1` (an older `<path>.1` becomes `<path>.2`, and so on up to
//! `keep`; the oldest is removed) and a new, empty file is started. A line
//! is never split across two files. With `keep` 0 the full file is removed.
//! Without a limit the file grows as before.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

/// The most rotated copies a config may ask to keep.
pub const MAX_KEEP: u32 = 9;

pub struct Rotating {
    path: PathBuf,
    file: File,
    size: u64,
    max_bytes: Option<u64>,
    keep: u32,
}

fn open(path: &Path) -> Result<File, String> {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    OpenOptions::new().create(true).append(true).open(path).map_err(|e| format!("cannot open {} for writing: {e}", path.display()))
}

/// `<path>.<n>`: the n-th older copy.
pub fn copy_path(path: &Path, n: u32) -> PathBuf {
    let mut s = path.as_os_str().to_owned();
    s.push(format!(".{n}"));
    PathBuf::from(s)
}

impl Rotating {
    pub fn open(path: &Path, max_mb: Option<u64>, keep: u32) -> Result<Rotating, String> {
        let file = open(path)?;
        let size = file.metadata().map(|m| m.len()).unwrap_or(0);
        Ok(Rotating { path: path.to_path_buf(), file, size, max_bytes: max_mb.map(|m| m * 1024 * 1024), keep })
    }

    /// Appends one line (without its newline).
    pub fn line(&mut self, text: &str) -> std::io::Result<()> {
        let n = text.len() as u64 + 1;
        if let Some(max) = self.max_bytes {
            if self.size > 0 && self.size + n > max {
                self.rotate()?;
            }
        }
        let mut buf = Vec::with_capacity(text.len() + 1);
        buf.extend_from_slice(text.as_bytes());
        buf.push(b'\n');
        self.file.write_all(&buf)?;
        self.size += n;
        Ok(())
    }

    /// Removes the older copies (`<path>.1` and on) whose last write is longer
    /// ago than `age`. The current file stays. Returns how many it removed.
    pub fn prune_older_than(&self, age: std::time::Duration) -> usize {
        let mut removed = 0;
        for i in 1..=self.keep.max(MAX_KEEP) {
            let p = copy_path(&self.path, i);
            let old = std::fs::metadata(&p).and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok()).is_some_and(|e| e > age);
            if old && std::fs::remove_file(&p).is_ok() {
                removed += 1;
            }
        }
        removed
    }

    /// The current file and its older copies, newest first.
    pub fn files(path: &Path, keep: u32) -> Vec<PathBuf> {
        std::iter::once(path.to_path_buf()).chain((1..=keep).map(|i| copy_path(path, i))).filter(|p| p.exists()).collect()
    }

    fn rotate(&mut self) -> std::io::Result<()> {
        if self.keep == 0 {
            std::fs::remove_file(&self.path)?;
        } else {
            let _ = std::fs::remove_file(copy_path(&self.path, self.keep));
            for i in (1..self.keep).rev() {
                let from = copy_path(&self.path, i);
                if from.exists() {
                    std::fs::rename(&from, copy_path(&self.path, i + 1))?;
                }
            }
            std::fs::rename(&self.path, copy_path(&self.path, 1))?;
        }
        self.file = open(&self.path).map_err(std::io::Error::other)?;
        self.size = 0;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("rotate-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn rotates_at_the_limit_and_keeps_that_many_copies() {
        let d = dir("keep");
        let p = d.join("out.jsonl");
        let mut r = Rotating::open(&p, Some(1), 2).unwrap();
        let line = "x".repeat(400 * 1024 - 1); // 400 KiB with its newline
        for _ in 0..8 {
            r.line(&line).unwrap();
        }
        // 8 lines, 2 per MiB file: the current file and two older copies.
        let size = |p: &Path| std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
        assert_eq!(size(&p), 2 * 400 * 1024);
        assert_eq!(size(&copy_path(&p, 1)), 2 * 400 * 1024);
        assert_eq!(size(&copy_path(&p, 2)), 2 * 400 * 1024);
        assert!(!copy_path(&p, 3).exists());
        // Every file holds whole lines.
        for f in [p.clone(), copy_path(&p, 1), copy_path(&p, 2)] {
            assert!(std::fs::read_to_string(&f).unwrap().lines().all(|l| l.len() == line.len()));
        }
    }

    #[test]
    fn keep_zero_removes_the_full_file_and_no_limit_never_rotates() {
        let d = dir("zero");
        let p = d.join("a.jsonl");
        let mut r = Rotating::open(&p, Some(1), 0).unwrap();
        let line = "y".repeat(700 * 1024);
        r.line(&line).unwrap();
        r.line(&line).unwrap();
        assert!(!copy_path(&p, 1).exists());
        assert_eq!(std::fs::read_to_string(&p).unwrap().lines().count(), 1);
        let q = d.join("b.jsonl");
        let mut r = Rotating::open(&q, None, 1).unwrap();
        for _ in 0..3 {
            r.line(&line).unwrap();
        }
        assert!(!copy_path(&q, 1).exists());
        assert_eq!(std::fs::read_to_string(&q).unwrap().lines().count(), 3);
    }

    #[test]
    fn an_existing_file_counts_toward_the_limit() {
        let d = dir("existing");
        let p = d.join("audit.jsonl");
        std::fs::write(&p, "z".repeat(1024 * 1024 - 10) + "\n").unwrap();
        let mut r = Rotating::open(&p, Some(1), 1).unwrap();
        r.line("0123456789abcdef").unwrap();
        assert!(copy_path(&p, 1).exists());
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "0123456789abcdef\n");
    }
}
