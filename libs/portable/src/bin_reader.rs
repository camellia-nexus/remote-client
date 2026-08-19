use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    io::{self, Cursor, Read, Write},
    path::{Component, Path, PathBuf},
};

use sha2::{Digest, Sha256};

#[cfg(windows)]
const BIN_DATA: &[u8] = include_bytes!("../data.bin");
#[cfg(not(windows))]
const BIN_DATA: &[u8] = &[];

const ARCHIVE_MAGIC: &[u8; 8] = b"CAMELP01";
const DIGEST_LENGTH: usize = 32;
const MAX_FILE_COUNT: usize = 100_000;
const MAX_PATH_LENGTH: usize = 32 * 1024;
const MAX_FILE_LENGTH: u64 = 1024 * 1024 * 1024;
const BUFFER_SIZE: usize = 64 * 1024;

pub(crate) struct BinaryData<'a> {
    compressed: &'a [u8],
    sha256_digest: [u8; DIGEST_LENGTH],
    uncompressed_length: u64,
    path: PathBuf,
}

pub(crate) struct BinaryReader<'a> {
    pub files: Vec<BinaryData<'a>>,
    pub exe: PathBuf,
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

fn take_bytes<'a>(data: &'a [u8], cursor: &mut usize, length: usize) -> io::Result<&'a [u8]> {
    let end = cursor
        .checked_add(length)
        .ok_or_else(|| invalid_data("portable archive offset overflow"))?;
    let bytes = data
        .get(*cursor..end)
        .ok_or_else(|| invalid_data("portable archive is truncated"))?;
    *cursor = end;
    Ok(bytes)
}

fn read_u32(data: &[u8], cursor: &mut usize) -> io::Result<u32> {
    let bytes: [u8; 4] = take_bytes(data, cursor, 4)?
        .try_into()
        .map_err(|_| invalid_data("portable archive contains an invalid u32"))?;
    Ok(u32::from_be_bytes(bytes))
}

fn read_u64(data: &[u8], cursor: &mut usize) -> io::Result<u64> {
    let bytes: [u8; 8] = take_bytes(data, cursor, 8)?
        .try_into()
        .map_err(|_| invalid_data("portable archive contains an invalid u64"))?;
    Ok(u64::from_be_bytes(bytes))
}

fn parse_archive_path(raw: &[u8], label: &str) -> io::Result<PathBuf> {
    if raw.is_empty() || raw.len() > MAX_PATH_LENGTH {
        return Err(invalid_data(format!("{label} has an invalid length")));
    }
    let value = std::str::from_utf8(raw)
        .map_err(|_| invalid_data(format!("{label} is not valid UTF-8")))?;
    if value.contains('\\')
        || value.contains(':')
        || value.contains('\0')
        || value
            .split('/')
            .any(|component| component.is_empty() || component == "." || component == "..")
    {
        return Err(invalid_data(format!("{label} is not a normalized path")));
    }

    let path = PathBuf::from(value);
    if !path.is_relative()
        || !path
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
    {
        return Err(invalid_data(format!("{label} must be a relative path")));
    }
    Ok(path)
}

fn sha256_file(path: &Path) -> io::Result<[u8; DIGEST_LENGTH]> {
    let mut file = File::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; BUFFER_SIZE];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    Ok(digest.finalize().into())
}

fn ensure_safe_parent(prefix: &Path, relative: &Path) -> io::Result<PathBuf> {
    match fs::symlink_metadata(prefix) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            return Err(invalid_data(format!(
                "portable extraction root is not a regular directory: {}",
                prefix.display()
            )));
        }
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::create_dir_all(prefix)?;
        }
        Err(error) => return Err(error),
    }

    let mut current = prefix.to_path_buf();
    if let Some(parent) = relative.parent() {
        for component in parent.components() {
            let Component::Normal(component) = component else {
                return Err(invalid_data("portable archive path escaped its root"));
            };
            current.push(component);
            match fs::symlink_metadata(&current) {
                Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
                    return Err(invalid_data(format!(
                        "portable extraction path contains an unsafe directory: {}",
                        current.display()
                    )));
                }
                Ok(_) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    fs::create_dir(&current)?;
                }
                Err(error) => return Err(error),
            }
        }
    }
    Ok(prefix.join(relative))
}

impl BinaryData<'_> {
    fn decompress(&self) -> io::Result<Vec<u8>> {
        let expected_length = usize::try_from(self.uncompressed_length)
            .map_err(|_| invalid_data("portable archive file does not fit this platform"))?;
        let cursor = Cursor::new(self.compressed);
        let decoder = brotli::Decompressor::new(cursor, BUFFER_SIZE);
        let mut limited = decoder.take(self.uncompressed_length.saturating_add(1));
        let mut content = Vec::with_capacity(expected_length.min(16 * 1024 * 1024));
        limited.read_to_end(&mut content)?;

        if content.len() != expected_length {
            return Err(invalid_data(format!(
                "portable archive size mismatch for {}",
                self.path.display()
            )));
        }
        let actual_digest: [u8; DIGEST_LENGTH] = Sha256::digest(&content).into();
        if actual_digest != self.sha256_digest {
            return Err(invalid_data(format!(
                "portable archive checksum mismatch for {}",
                self.path.display()
            )));
        }
        Ok(content)
    }

    pub fn write_to_file(&self, prefix: &Path) -> io::Result<()> {
        let path = ensure_safe_parent(prefix, &self.path)?;
        match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
                return Err(invalid_data(format!(
                    "portable extraction target is unsafe: {}",
                    path.display()
                )));
            }
            Ok(_) if sha256_file(&path)? == self.sha256_digest => {
                println!("Verified {}", self.path.display());
                return Ok(());
            }
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }

        let content = self.decompress()?;
        let file_name = path
            .file_name()
            .ok_or_else(|| invalid_data("portable archive target has no file name"))?
            .to_string_lossy();
        let mut temporary = None;
        for attempt in 0..100 {
            let candidate = path.with_file_name(format!(
                ".{file_name}.camellia-{}-{attempt}.tmp",
                std::process::id()
            ));
            match OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&candidate)
            {
                Ok(file) => {
                    temporary = Some((candidate, file));
                    break;
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(error),
            }
        }
        let (temporary_path, mut temporary_file) = temporary.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::AlreadyExists,
                "could not allocate a portable extraction temporary file",
            )
        })?;

        let write_result = (|| -> io::Result<()> {
            temporary_file.write_all(&content)?;
            temporary_file.sync_all()?;
            drop(temporary_file);

            match fs::rename(&temporary_path, &path) {
                Ok(()) => Ok(()),
                Err(first_error)
                    if matches!(
                        first_error.kind(),
                        io::ErrorKind::AlreadyExists | io::ErrorKind::PermissionDenied
                    ) =>
                {
                    let metadata = fs::symlink_metadata(&path).map_err(|_| first_error)?;
                    if metadata.file_type().is_symlink() || !metadata.is_file() {
                        return Err(invalid_data(format!(
                            "portable extraction target changed unexpectedly: {}",
                            path.display()
                        )));
                    }
                    fs::remove_file(&path)?;
                    fs::rename(&temporary_path, &path)
                }
                Err(error) => Err(error),
            }
        })();
        if write_result.is_err() {
            let _ = fs::remove_file(&temporary_path);
        }
        write_result?;
        println!("Extracted {}", self.path.display());
        Ok(())
    }
}

impl BinaryReader<'static> {
    pub fn embedded(expected_sha256: &str) -> io::Result<Self> {
        let actual_sha256 = format!("{:x}", Sha256::digest(BIN_DATA));
        if actual_sha256 != expected_sha256 {
            return Err(invalid_data(
                "embedded portable archive does not match its package metadata",
            ));
        }
        Self::read(BIN_DATA)
    }
}

impl<'a> BinaryReader<'a> {
    fn read(data: &'a [u8]) -> io::Result<Self> {
        let mut cursor = 0;
        if take_bytes(data, &mut cursor, ARCHIVE_MAGIC.len())? != ARCHIVE_MAGIC {
            return Err(invalid_data(
                "portable archive has an invalid format marker",
            ));
        }

        let file_count = usize::try_from(read_u32(data, &mut cursor)?)
            .map_err(|_| invalid_data("portable archive file count is unsupported"))?;
        if file_count == 0 || file_count > MAX_FILE_COUNT {
            return Err(invalid_data("portable archive has an invalid file count"));
        }

        let mut files = Vec::with_capacity(file_count);
        let mut paths = HashSet::with_capacity(file_count);
        for _ in 0..file_count {
            let path_length = usize::try_from(read_u32(data, &mut cursor)?)
                .map_err(|_| invalid_data("portable archive path is too long"))?;
            let compressed_length = read_u64(data, &mut cursor)?;
            let uncompressed_length = read_u64(data, &mut cursor)?;
            if compressed_length > MAX_FILE_LENGTH || uncompressed_length > MAX_FILE_LENGTH {
                return Err(invalid_data("portable archive file exceeds the size limit"));
            }
            let compressed_length = usize::try_from(compressed_length)
                .map_err(|_| invalid_data("portable archive file does not fit this platform"))?;
            let sha256_digest: [u8; DIGEST_LENGTH] = take_bytes(data, &mut cursor, DIGEST_LENGTH)?
                .try_into()
                .map_err(|_| invalid_data("portable archive checksum is invalid"))?;
            let path =
                parse_archive_path(take_bytes(data, &mut cursor, path_length)?, "archive path")?;
            if !paths.insert(path.clone()) {
                return Err(invalid_data(format!(
                    "portable archive contains a duplicate path: {}",
                    path.display()
                )));
            }
            let compressed = take_bytes(data, &mut cursor, compressed_length)?;
            files.push(BinaryData {
                compressed,
                sha256_digest,
                uncompressed_length,
                path,
            });
        }

        let executable_length = usize::try_from(read_u32(data, &mut cursor)?)
            .map_err(|_| invalid_data("portable executable path is too long"))?;
        let exe = parse_archive_path(
            take_bytes(data, &mut cursor, executable_length)?,
            "executable path",
        )?;
        if cursor != data.len() {
            return Err(invalid_data("portable archive contains trailing data"));
        }
        if !paths.contains(&exe) {
            return Err(invalid_data(
                "portable executable is not present in the archive",
            ));
        }
        Ok(Self { files, exe })
    }

    #[cfg(target_os = "linux")]
    pub fn configure_permission(&self, prefix: &Path) -> io::Result<()> {
        use std::os::unix::fs::PermissionsExt;

        let executable = prefix.join(&self.exe);
        let mut permissions = fs::metadata(&executable)?.permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(executable, permissions)
    }
}

/// Runs the production archive parser without extracting any files.
///
/// Dynamic test harnesses use this entry point so malformed input exercises
/// exactly the same length, path, digest, and decompression metadata parser as
/// the portable launcher.
#[allow(dead_code)]
pub(crate) fn validate_archive(data: &[u8]) -> io::Result<()> {
    BinaryReader::read(data).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::Write,
        sync::atomic::{AtomicUsize, Ordering},
    };

    static TEST_DIRECTORY_COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn compress(content: &[u8]) -> Vec<u8> {
        let mut output = Vec::new();
        {
            let mut compressor = brotli::CompressorWriter::new(&mut output, BUFFER_SIZE, 11, 22);
            compressor.write_all(content).unwrap();
        }
        output
    }

    fn archive(entries: &[(&str, &[u8])], executable: &str) -> Vec<u8> {
        let mut output = ARCHIVE_MAGIC.to_vec();
        output.extend_from_slice(&(entries.len() as u32).to_be_bytes());
        for (path, content) in entries {
            let path = path.as_bytes();
            let compressed = compress(content);
            output.extend_from_slice(&(path.len() as u32).to_be_bytes());
            output.extend_from_slice(&(compressed.len() as u64).to_be_bytes());
            output.extend_from_slice(&(content.len() as u64).to_be_bytes());
            output.extend_from_slice(&Sha256::digest(content));
            output.extend_from_slice(path);
            output.extend_from_slice(&compressed);
        }
        output.extend_from_slice(&(executable.len() as u32).to_be_bytes());
        output.extend_from_slice(executable.as_bytes());
        output
    }

    fn temporary_directory() -> PathBuf {
        let sequence = TEST_DIRECTORY_COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "camellia-portable-test-{}-{sequence}",
            std::process::id()
        ))
    }

    #[test]
    fn parses_verifies_and_extracts_archive() {
        let data = archive(
            &[
                ("bin/camellia-remote.exe", b"portable executable"),
                ("data/empty.txt", b""),
            ],
            "bin/camellia-remote.exe",
        );
        let reader = BinaryReader::read(&data).unwrap();
        assert_eq!(reader.files.len(), 2);
        assert_eq!(reader.exe, Path::new("bin/camellia-remote.exe"));

        let directory = temporary_directory();
        fs::create_dir(&directory).unwrap();
        for file in &reader.files {
            file.write_to_file(&directory).unwrap();
            file.write_to_file(&directory).unwrap();
        }
        assert_eq!(
            fs::read(directory.join("bin/camellia-remote.exe")).unwrap(),
            b"portable executable"
        );
        assert_eq!(fs::read(directory.join("data/empty.txt")).unwrap(), b"");
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn rejects_unsafe_and_duplicate_paths() {
        for path in [
            "../camellia-remote.exe",
            "/camellia-remote.exe",
            "bin//camellia-remote.exe",
            "bin/./camellia-remote.exe",
            "C:/camellia-remote.exe",
            r"bin\camellia-remote.exe",
        ] {
            let data = archive(&[(path, b"payload")], path);
            assert!(BinaryReader::read(&data).is_err(), "{path}");
        }

        let duplicate = archive(
            &[
                ("camellia-remote.exe", b"first"),
                ("camellia-remote.exe", b"second"),
            ],
            "camellia-remote.exe",
        );
        assert!(BinaryReader::read(&duplicate).is_err());
    }

    #[test]
    fn rejects_truncated_trailing_and_missing_executable_data() {
        let data = archive(
            &[("camellia-remote.exe", b"payload")],
            "camellia-remote.exe",
        );
        assert!(BinaryReader::read(&data[..data.len() - 1]).is_err());

        let mut trailing = data.clone();
        trailing.push(0);
        assert!(BinaryReader::read(&trailing).is_err());

        let missing = archive(&[("other.exe", b"payload")], "camellia-remote.exe");
        assert!(BinaryReader::read(&missing).is_err());
    }

    #[test]
    fn rejects_corrupt_content_before_extraction() {
        let mut data = archive(
            &[("camellia-remote.exe", b"payload")],
            "camellia-remote.exe",
        );
        let digest_start = ARCHIVE_MAGIC.len() + 4 + 4 + 8 + 8;
        data[digest_start] ^= 0xff;
        let reader = BinaryReader::read(&data).unwrap();
        assert!(reader.files[0].decompress().is_err());
    }
}
