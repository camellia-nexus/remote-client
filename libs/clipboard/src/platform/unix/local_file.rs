use super::{BLOCK_SIZE, LDAP_EPOCH_DELTA};
use crate::{
    platform::unix::{
        FLAGS_FD_ATTRIBUTES, FLAGS_FD_LAST_WRITE, FLAGS_FD_PROGRESSUI, FLAGS_FD_SIZE,
        FLAGS_FD_UNIX_MODE,
    },
    CliprdrError,
};
use camellia_remote_protocol::{
    bytes::{BufMut, BytesMut},
    log,
};
use cap_fs_ext::{DirExt, FollowSymlinks, OpenOptionsFollowExt};
use cap_std::{
    ambient_authority,
    fs::{
        Dir, Metadata, MetadataExt as CapMetadataExt, OpenOptions as CapOpenOptions, PermissionsExt,
    },
};
use std::{
    collections::HashSet,
    fs::File,
    io::{BufRead, BufReader, Read, Seek},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::SystemTime,
};
use utf16string::WString;

pub const MAX_CLIPBOARD_RECURSION_DEPTH: usize = 64;
pub const MAX_CLIPBOARD_FILE_ENTRIES: usize = 10_000;
pub const MAX_CLIPBOARD_NAME_BYTES: usize = 520;
pub const MAX_CLIPBOARD_PDU_BYTES: usize = 8 * 1024 * 1024; // 8 MiB

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct FileIdentity {
    device: u64,
    inode: u64,
    ctime_seconds: i64,
    ctime_nanoseconds: i64,
    size: u64,
}

impl FileIdentity {
    fn from_metadata(metadata: &Metadata) -> Self {
        Self {
            device: CapMetadataExt::dev(metadata),
            inode: CapMetadataExt::ino(metadata),
            ctime_seconds: CapMetadataExt::ctime(metadata),
            ctime_nanoseconds: CapMetadataExt::ctime_nsec(metadata),
            size: metadata.len(),
        }
    }
}

#[derive(Debug)]
struct LocalFileSource {
    authority: Arc<Dir>,
    relative_path: PathBuf,
    identity: FileIdentity,
}

#[derive(Debug)]
pub(super) struct LocalFile {
    pub relative_root: PathBuf,
    pub path: PathBuf,

    pub handle: Option<BufReader<File>>,
    pub offset: AtomicU64,

    pub name: String,
    pub size: u64,
    pub last_write_time: SystemTime,
    pub is_dir: bool,
    pub perm: u32,
    pub read_only: bool,
    pub hidden: bool,
    pub system: bool,
    pub archive: bool,
    pub normal: bool,

    source: Option<LocalFileSource>,
}

impl LocalFile {
    #[cfg(test)]
    pub fn try_open(relative_root: &Path, path: &Path) -> Result<Self, CliprdrError> {
        let parent_path = path.parent().ok_or_else(|| CliprdrError::InvalidRequest {
            description: format!("clipboard path has no parent: {}", path.display()),
        })?;
        let entry_name = path
            .file_name()
            .ok_or_else(|| CliprdrError::InvalidRequest {
                description: format!("clipboard path has no file name: {}", path.display()),
            })?
            .to_os_string();
        let authority = Arc::new(
            Dir::open_ambient_dir(parent_path, ambient_authority()).map_err(|e| {
                CliprdrError::FileError {
                    path: parent_path.to_string_lossy().to_string(),
                    err: e,
                }
            })?,
        );
        Self::try_open_at(
            relative_root,
            path,
            authority.as_ref(),
            Arc::clone(&authority),
            PathBuf::from(entry_name),
        )
    }

    fn try_open_at(
        relative_root: &Path,
        path: &Path,
        parent: &Dir,
        authority: Arc<Dir>,
        relative_path: PathBuf,
    ) -> Result<Self, CliprdrError> {
        let entry_name = relative_path
            .file_name()
            .ok_or_else(|| CliprdrError::InvalidRequest {
                description: format!("clipboard path has no file name: {}", path.display()),
            })?;
        let mt = parent
            .symlink_metadata(entry_name)
            .map_err(|e| CliprdrError::FileError {
                path: path.to_string_lossy().to_string(),
                err: e,
            })?;
        if mt.file_type().is_symlink() {
            return Err(CliprdrError::InvalidRequest {
                description: format!(
                    "symbolic links are not allowed in clipboard file selections: {}",
                    path.display()
                ),
            });
        }
        let identity = FileIdentity::from_metadata(&mt);
        let size = mt.len();
        let is_dir = mt.is_dir();
        let read_only = mt.permissions().readonly();
        let system = false;
        let hidden = path.to_string_lossy().starts_with('.');
        let archive = false;
        let normal = !(is_dir || read_only || system || hidden || archive);
        let last_write_time = mt
            .modified()
            .map(|time| time.into_std())
            .unwrap_or(SystemTime::UNIX_EPOCH);

        let perm = mt.permissions().mode();

        let name = path
            .display()
            .to_string()
            .trim_start_matches('/')
            .replace('/', "\\");

        // Open files lazily from the selected root's stable parent capability.
        let handle = None;
        let offset = AtomicU64::new(0);

        Ok(Self {
            name,
            relative_root: relative_root.to_path_buf(),
            path: path.to_path_buf(),
            handle,
            offset,
            size,
            last_write_time,
            is_dir,
            read_only,
            system,
            hidden,
            perm,
            archive,
            normal,
            source: Some(LocalFileSource {
                authority,
                relative_path,
                identity,
            }),
        })
    }

    fn identity(&self) -> Result<FileIdentity, CliprdrError> {
        self.source
            .as_ref()
            .map(|source| source.identity)
            .ok_or_else(|| CliprdrError::InvalidRequest {
                description: format!(
                    "clipboard file has no source identity: {}",
                    self.path.display()
                ),
            })
    }

    fn source_authority_and_path(&self) -> Result<(&Arc<Dir>, &Path), CliprdrError> {
        self.source
            .as_ref()
            .map(|source| (&source.authority, source.relative_path.as_path()))
            .ok_or_else(|| CliprdrError::InvalidRequest {
                description: format!(
                    "clipboard file has no source capability: {}",
                    self.path.display()
                ),
            })
    }

    fn open_source_file(&self) -> Result<cap_std::fs::File, CliprdrError> {
        let (authority, relative_path) = self.source_authority_and_path()?;
        let file_name = relative_path
            .file_name()
            .ok_or_else(|| CliprdrError::InvalidRequest {
                description: format!(
                    "clipboard file has no relative name: {}",
                    self.path.display()
                ),
            })?;
        let mut parent = authority.try_clone().map_err(|err| self.file_error(err))?;
        if let Some(parent_path) = relative_path.parent() {
            for component in parent_path.components() {
                let std::path::Component::Normal(component) = component else {
                    if matches!(component, std::path::Component::CurDir) {
                        continue;
                    }
                    return Err(CliprdrError::InvalidRequest {
                        description: format!(
                            "invalid clipboard source path: {}",
                            relative_path.display()
                        ),
                    });
                };
                parent = parent
                    .open_dir_nofollow(component)
                    .map_err(|err| self.file_error(err))?;
            }
        }
        let mut options = CapOpenOptions::new();
        options.read(true).follow(FollowSymlinks::No);
        parent
            .open_with(file_name, &options)
            .map_err(|err| self.file_error(err))
    }

    fn validate_opened_identity(&self, metadata: &Metadata) -> Result<(), CliprdrError> {
        if FileIdentity::from_metadata(metadata) != self.identity()? {
            return Err(CliprdrError::InvalidRequest {
                description: format!(
                    "clipboard file changed after selection: {}",
                    self.path.display()
                ),
            });
        }
        Ok(())
    }

    fn file_error(&self, err: std::io::Error) -> CliprdrError {
        CliprdrError::FileError {
            path: self.path.to_string_lossy().to_string(),
            err,
        }
    }
    pub fn as_bin(&self) -> Result<Vec<u8>, CliprdrError> {
        let mut buf = BytesMut::with_capacity(592);

        let read_only_flag = if self.read_only { 0x1 } else { 0 };
        let hidden_flag = if self.hidden { 0x2 } else { 0 };
        let system_flag = if self.system { 0x4 } else { 0 };
        let directory_flag = if self.is_dir { 0x10 } else { 0 };
        let archive_flag = if self.archive { 0x20 } else { 0 };
        let normal_flag = if self.normal { 0x80 } else { 0 };

        let file_attributes: u32 = read_only_flag
            | hidden_flag
            | system_flag
            | directory_flag
            | archive_flag
            | normal_flag;

        let win32_time = self
            .last_write_time
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos() as u64
            / 100
            + LDAP_EPOCH_DELTA;

        let size_high = (self.size >> 32) as u32;
        let size_low = (self.size & (u32::MAX as u64)) as u32;

        let stripped = self
            .path
            .strip_prefix(&self.relative_root)
            .unwrap_or(&self.path);
        let path = if stripped.as_os_str().is_empty() {
            ".".to_string()
        } else {
            stripped.to_string_lossy().into_owned()
        };

        let wstr: WString<utf16string::LE> = WString::from(&path);
        let name = wstr.as_bytes();

        let name_len = name.len();
        if name_len > MAX_CLIPBOARD_NAME_BYTES {
            return Err(CliprdrError::InvalidRequest {
                description: format!(
                    "descriptor name length ({}) exceeds max 520 bytes: {}",
                    name_len,
                    self.path.display()
                ),
            });
        }

        log::trace!(
            "put file to list: name_len {}, name {}",
            name_len,
            &self.name
        );

        let flags = FLAGS_FD_SIZE
            | FLAGS_FD_LAST_WRITE
            | FLAGS_FD_ATTRIBUTES
            | FLAGS_FD_PROGRESSUI
            | FLAGS_FD_UNIX_MODE;

        // flags, 4 bytes
        buf.put_u32_le(flags);
        // 32 bytes reserved
        buf.put(&[0u8; 32][..]);
        // file attributes, 4 bytes
        buf.put_u32_le(file_attributes);

        // NOTE: this is not used in windows
        // in the specification, this is 16 bytes reserved
        // lets use the last 4 bytes to store the file mode
        //
        // 12 bytes reserved
        buf.put(&[0u8; 12][..]);
        // file permissions, 4 bytes
        buf.put_u32_le(self.perm);

        // last write time, 8 bytes
        buf.put_u64_le(win32_time);
        // file size (high)
        buf.put_u32_le(size_high);
        // file size (low)
        buf.put_u32_le(size_low);
        // put name and padding to 520 bytes
        buf.put(name);
        buf.put(&vec![0u8; 520 - name_len][..]);

        Ok(buf.to_vec())
    }

    #[inline]
    pub fn load_handle(&mut self) -> Result<(), CliprdrError> {
        if !self.is_dir && self.handle.is_none() {
            let file = self.open_source_file()?;
            let metadata = file.metadata().map_err(|err| self.file_error(err))?;
            self.validate_opened_identity(&metadata)?;
            let handle = file.into_std();
            let mut reader = BufReader::with_capacity(BLOCK_SIZE as usize * 2, handle);
            reader.fill_buf().map_err(|err| self.file_error(err))?;
            self.handle = Some(reader);
        };
        Ok(())
    }

    pub fn read_exact_at(&mut self, buf: &mut [u8], offset: u64) -> Result<(), CliprdrError> {
        self.load_handle()?;

        let Some(handle) = self.handle.as_mut() else {
            return Err(CliprdrError::FileError {
                path: self.path.to_string_lossy().to_string(),
                err: std::io::Error::new(std::io::ErrorKind::NotFound, "file handle not found"),
            });
        };

        let read_result = if offset != self.offset.load(Ordering::Relaxed) {
            handle
                .seek(std::io::SeekFrom::Start(offset))
                .and_then(|_| handle.read_exact(buf))
        } else {
            handle.read_exact(buf)
        };
        if let Err(e) = read_result {
            return Err(self.invalidate_handle(e));
        }
        let new_offset = offset + (buf.len() as u64);
        self.offset.store(new_offset, Ordering::Relaxed);

        // gc file handle
        if new_offset >= self.size {
            self.offset.store(0, Ordering::Relaxed);
            self.handle = None;
        }

        Ok(())
    }

    fn invalidate_handle(&mut self, err: std::io::Error) -> CliprdrError {
        self.offset.store(0, Ordering::Relaxed);
        self.handle = None;
        CliprdrError::FileError {
            path: self.path.to_string_lossy().to_string(),
            err,
        }
    }
}

pub(super) fn construct_file_list(paths: &[PathBuf]) -> Result<Vec<LocalFile>, CliprdrError> {
    fn constr_file_lst(
        relative_root: &Path,
        path: &Path,
        parent: &Dir,
        authority: Arc<Dir>,
        relative_path: PathBuf,
        file_list: &mut Vec<LocalFile>,
        visited_directories: &mut HashSet<FileIdentity>,
        depth: usize,
    ) -> Result<(), CliprdrError> {
        if depth > MAX_CLIPBOARD_RECURSION_DEPTH {
            return Err(CliprdrError::InvalidRequest {
                description: format!(
                    "directory recursion depth exceeds maximum allowed limit of {}: {}",
                    MAX_CLIPBOARD_RECURSION_DEPTH,
                    path.display()
                ),
            });
        }
        if file_list.len() >= MAX_CLIPBOARD_FILE_ENTRIES {
            return Err(CliprdrError::InvalidRequest {
                description: format!(
                    "total file entries count exceeds maximum allowed limit of {}: {}",
                    MAX_CLIPBOARD_FILE_ENTRIES,
                    path.display()
                ),
            });
        }
        let entry_name = relative_path
            .file_name()
            .ok_or_else(|| CliprdrError::InvalidRequest {
                description: format!("clipboard path has no file name: {}", path.display()),
            })?;
        let local_file = LocalFile::try_open_at(
            relative_root,
            path,
            parent,
            Arc::clone(&authority),
            relative_path.clone(),
        )?;
        let identity = local_file.identity()?;
        let is_dir = local_file.is_dir;
        if is_dir && !visited_directories.insert(identity) {
            return Ok(());
        }
        file_list.push(local_file);

        if is_dir {
            let directory =
                parent
                    .open_dir_nofollow(entry_name)
                    .map_err(|e| CliprdrError::FileError {
                        path: path.to_string_lossy().to_string(),
                        err: e,
                    })?;
            let opened_identity = directory
                .dir_metadata()
                .map(|metadata| FileIdentity::from_metadata(&metadata))
                .map_err(|e| CliprdrError::FileError {
                    path: path.to_string_lossy().to_string(),
                    err: e,
                })?;
            if opened_identity != identity {
                return Err(CliprdrError::InvalidRequest {
                    description: format!(
                        "clipboard directory changed after selection: {}",
                        path.display()
                    ),
                });
            }
            let entries = directory.entries().map_err(|e| CliprdrError::FileError {
                path: path.to_string_lossy().to_string(),
                err: e,
            })?;
            for entry in entries {
                let entry = entry.map_err(|e| CliprdrError::FileError {
                    path: path.to_string_lossy().to_string(),
                    err: e,
                })?;
                let entry_name = entry.file_name();
                let child_path = path.join(&entry_name);
                constr_file_lst(
                    relative_root,
                    &child_path,
                    &directory,
                    Arc::clone(&authority),
                    relative_path.join(entry_name),
                    file_list,
                    visited_directories,
                    depth + 1,
                )?;
            }
            let final_identity = directory
                .dir_metadata()
                .map(|metadata| FileIdentity::from_metadata(&metadata))
                .map_err(|e| CliprdrError::FileError {
                    path: path.to_string_lossy().to_string(),
                    err: e,
                })?;
            if final_identity != identity {
                return Err(CliprdrError::InvalidRequest {
                    description: format!(
                        "clipboard directory changed during enumeration: {}",
                        path.display()
                    ),
                });
            }
        }
        Ok(())
    }

    let mut file_list = Vec::new();
    let mut visited_directories = HashSet::new();

    let relative_root = paths
        .first()
        .ok_or(CliprdrError::InvalidRequest {
            description: "empty file list".to_string(),
        })?
        .parent()
        .ok_or(CliprdrError::InvalidRequest {
            description: "empty parent".to_string(),
        })?
        .to_path_buf();
    for path in paths {
        let parent_path = path.parent().ok_or_else(|| CliprdrError::InvalidRequest {
            description: format!("clipboard path has no parent: {}", path.display()),
        })?;
        let entry_name = path
            .file_name()
            .ok_or_else(|| CliprdrError::InvalidRequest {
                description: format!("clipboard path has no file name: {}", path.display()),
            })?
            .to_os_string();
        let authority = Arc::new(
            Dir::open_ambient_dir(parent_path, ambient_authority()).map_err(|e| {
                CliprdrError::FileError {
                    path: parent_path.to_string_lossy().to_string(),
                    err: e,
                }
            })?,
        );
        constr_file_lst(
            &relative_root,
            path,
            authority.as_ref(),
            Arc::clone(&authority),
            PathBuf::from(entry_name),
            &mut file_list,
            &mut visited_directories,
            0,
        )?;
    }
    Ok(file_list)
}

#[cfg(test)]
mod file_list_test {
    use std::{
        fs,
        os::unix::fs::symlink,
        path::PathBuf,
        sync::atomic::{AtomicU64, Ordering},
        time::{SystemTime, UNIX_EPOCH},
    };

    use camellia_remote_protocol::bytes::{BufMut, BytesMut};

    use crate::{platform::unix::filetype::FileDescription, CliprdrError};

    use super::{construct_file_list, LocalFile};

    struct TestDir(PathBuf);

    impl TestDir {
        fn new(tag: &str) -> Result<Self, Box<dyn std::error::Error>> {
            let nonce = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
            let path = std::env::temp_dir().join(format!(
                "camellia-clipboard-{tag}-{}-{nonce}",
                std::process::id()
            ));
            fs::create_dir_all(&path)?;
            Ok(Self(path))
        }

        fn join(&self, path: &str) -> PathBuf {
            self.0.join(path)
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn assert_symlink_rejected(result: Result<Vec<LocalFile>, CliprdrError>) {
        assert!(matches!(
            result,
            Err(CliprdrError::InvalidRequest { description })
                if description.contains("symbolic links are not allowed")
        ));
    }

    #[inline]
    fn generate_tree(prefix: &str) -> Vec<LocalFile> {
        // generate a tree of local files, no handles
        // - /
        // |- a.txt
        // |- b
        //    |- c.txt
        #[inline]
        fn generate_file(path: &str, name: &str, is_dir: bool) -> LocalFile {
            LocalFile {
                relative_root: PathBuf::from("."),
                path: PathBuf::from(path),
                handle: None,
                name: name.to_string(),
                size: 0,
                offset: AtomicU64::new(0),
                last_write_time: std::time::SystemTime::UNIX_EPOCH,
                read_only: false,
                is_dir,
                perm: 0o754,
                hidden: false,
                system: false,
                archive: false,
                normal: false,
                source: None,
            }
        }

        let p = prefix;

        let (r_path, a_path, b_path, c_path) = if !prefix.is_empty() {
            (
                p.to_string(),
                format!("{}/a.txt", p),
                format!("{}/b", p),
                format!("{}/b/c.txt", p),
            )
        } else {
            (
                ".".to_string(),
                "a.txt".to_string(),
                "b".to_string(),
                "b/c.txt".to_string(),
            )
        };

        let root = generate_file(&r_path, ".", true);
        let a = generate_file(&a_path, "a.txt", false);
        let b = generate_file(&b_path, "b", true);
        let c = generate_file(&c_path, "c.txt", false);

        vec![root, a, b, c]
    }

    fn as_bin_parse_test(prefix: &str) -> Result<(), CliprdrError> {
        let tree = generate_tree(prefix);
        let mut pdu = BytesMut::with_capacity(4 + 592 * tree.len());
        pdu.put_u32_le(tree.len() as u32);
        for file in tree {
            pdu.put(file.as_bin()?.as_slice());
        }

        let parsed = FileDescription::parse_file_descriptors(pdu.to_vec(), 0)?;
        assert_eq!(parsed.len(), 4);

        if !prefix.is_empty() {
            assert_eq!(parsed[0].name.to_str().unwrap(), format!("{}", prefix));
            assert_eq!(
                parsed[1].name.to_str().unwrap(),
                format!("{}/a.txt", prefix)
            );
            assert_eq!(parsed[2].name.to_str().unwrap(), format!("{}/b", prefix));
            assert_eq!(
                parsed[3].name.to_str().unwrap(),
                format!("{}/b/c.txt", prefix)
            );
        } else {
            assert_eq!(parsed[0].name.to_str().unwrap(), ".");
            assert_eq!(parsed[1].name.to_str().unwrap(), "a.txt");
            assert_eq!(parsed[2].name.to_str().unwrap(), "b");
            assert_eq!(parsed[3].name.to_str().unwrap(), "b/c.txt");
        }

        assert!(parsed[0].perm & 0o777 == 0o754);
        assert!(parsed[1].perm & 0o777 == 0o754);
        assert!(parsed[2].perm & 0o777 == 0o754);
        assert!(parsed[3].perm & 0o777 == 0o754);

        Ok(())
    }

    #[test]
    fn test_parse_file_descriptors() -> Result<(), CliprdrError> {
        as_bin_parse_test("")?;
        as_bin_parse_test("/")?;
        as_bin_parse_test("test")?;
        as_bin_parse_test("/test")?;
        Ok(())
    }

    #[test]
    fn read_exact_at_reopens_after_read_failure() -> Result<(), Box<dyn std::error::Error>> {
        let file_path = std::env::temp_dir().join(format!(
            "rustdesk-clipboard-local-file-{}",
            std::process::id()
        ));
        std::fs::write(&file_path, [42u8])?;

        let mut file = LocalFile::try_open(&std::env::temp_dir(), &file_path)?;
        file.size = 2;

        let mut buf = [0u8; 2];
        assert!(file.read_exact_at(&mut buf, 0).is_err());
        assert!(file.handle.is_none());
        assert_eq!(file.offset.load(Ordering::Relaxed), 0);

        file.size = 1;
        let mut buf = [0u8; 1];
        file.read_exact_at(&mut buf, 0)?;
        assert_eq!(buf, [42u8]);
        assert!(file.handle.is_none());

        std::fs::remove_file(file_path)?;
        Ok(())
    }

    #[test]
    fn selected_symlink_root_is_rejected() -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("symlink-root")?;
        let target = temp.join("target");
        fs::create_dir(&target)?;
        fs::write(target.join("inside.txt"), b"inside")?;
        let selected = temp.join("selected");
        symlink(&target, &selected)?;

        assert_symlink_rejected(construct_file_list(&[selected]));
        Ok(())
    }

    #[test]
    fn symlinks_inside_selection_are_rejected_even_when_target_is_inside(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("inside-symlink")?;
        let selected = temp.join("selected");
        fs::create_dir(&selected)?;
        let target = selected.join("target.txt");
        fs::write(&target, b"inside")?;
        symlink(&target, selected.join("alias.txt"))?;

        assert_symlink_rejected(construct_file_list(&[selected]));
        Ok(())
    }

    #[test]
    fn directory_symlink_cannot_enumerate_outside_selection(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("outside-directory")?;
        let selected = temp.join("selected");
        let outside = temp.join("outside");
        fs::create_dir(&selected)?;
        fs::create_dir(&outside)?;
        fs::write(outside.join("secret.txt"), b"secret")?;
        symlink(&outside, selected.join("leak"))?;

        assert_symlink_rejected(construct_file_list(&[selected]));
        Ok(())
    }

    #[test]
    fn self_symlink_cycle_is_rejected_before_recursion() -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("self-cycle")?;
        let selected = temp.join("selected");
        fs::create_dir(&selected)?;
        symlink(".", selected.join("self"))?;

        assert_symlink_rejected(construct_file_list(&[selected]));
        Ok(())
    }

    #[test]
    fn ancestor_symlink_cycle_is_rejected_before_recursion(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("ancestor-cycle")?;
        let selected = temp.join("selected");
        let child = selected.join("child");
        fs::create_dir_all(&child)?;
        symlink("..", child.join("parent"))?;

        assert_symlink_rejected(construct_file_list(&[selected]));
        Ok(())
    }

    #[test]
    fn file_swapped_for_symlink_after_enumeration_is_not_read(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("file-swap")?;
        let selected = temp.join("selected");
        fs::create_dir(&selected)?;
        let selected_file = selected.join("shared.txt");
        fs::write(&selected_file, b"public")?;
        let secret = temp.join("secret.txt");
        fs::write(&secret, b"secret")?;

        let mut files = construct_file_list(&[selected])?;
        let file = files
            .iter_mut()
            .find(|file| file.path == selected_file)
            .ok_or("selected file is missing from descriptor list")?;
        fs::remove_file(&selected_file)?;
        symlink(&secret, &selected_file)?;

        let mut data = [0_u8; 6];
        assert!(file.read_exact_at(&mut data, 0).is_err());
        Ok(())
    }

    #[test]
    fn parent_directory_swapped_for_symlink_after_enumeration_is_not_followed(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("parent-swap")?;
        let selected = temp.join("selected");
        let nested = selected.join("nested");
        fs::create_dir_all(&nested)?;
        let selected_file = nested.join("shared.txt");
        fs::write(&selected_file, b"public")?;
        let outside = temp.join("outside");
        fs::create_dir(&outside)?;
        fs::write(outside.join("shared.txt"), b"secret")?;

        let mut files = construct_file_list(std::slice::from_ref(&selected))?;
        let file = files
            .iter_mut()
            .find(|file| file.path == selected_file)
            .ok_or("selected file is missing from descriptor list")?;
        fs::rename(&nested, selected.join("original-nested"))?;
        symlink(&outside, &nested)?;

        let mut data = [0_u8; 6];
        assert!(file.read_exact_at(&mut data, 0).is_err());
        Ok(())
    }

    #[test]
    fn file_generation_change_after_enumeration_is_rejected(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("generation-change")?;
        let selected = temp.join("selected");
        fs::create_dir(&selected)?;
        let selected_file = selected.join("shared.txt");
        fs::write(&selected_file, b"public")?;

        let mut files = construct_file_list(&[selected])?;
        let file = files
            .iter_mut()
            .find(|file| file.path == selected_file)
            .ok_or("selected file is missing from descriptor list")?;
        fs::write(&selected_file, b"secret")?;

        let mut data = [0_u8; 6];
        assert!(file.read_exact_at(&mut data, 0).is_err());
        Ok(())
    }

    #[test]
    fn file_deleted_after_enumeration_is_not_read() -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("deleted-file")?;
        let selected = temp.join("selected");
        fs::create_dir(&selected)?;
        let selected_file = selected.join("shared.txt");
        fs::write(&selected_file, b"public")?;

        let mut files = construct_file_list(std::slice::from_ref(&selected))?;
        let file = files
            .iter_mut()
            .find(|file| file.path == selected_file)
            .ok_or("selected file is missing from descriptor list")?;
        fs::remove_file(&selected_file)?;

        let mut data = [0_u8; 6];
        assert!(file.read_exact_at(&mut data, 0).is_err());
        Ok(())
    }

    #[test]
    fn permission_change_after_enumeration_is_rejected() -> Result<(), Box<dyn std::error::Error>> {
        use std::os::unix::fs::PermissionsExt;

        let temp = TestDir::new("permission-change")?;
        let selected = temp.join("selected");
        fs::create_dir(&selected)?;
        let selected_file = selected.join("shared.txt");
        fs::write(&selected_file, b"public")?;
        fs::set_permissions(&selected_file, fs::Permissions::from_mode(0o600))?;

        let mut files = construct_file_list(std::slice::from_ref(&selected))?;
        let file = files
            .iter_mut()
            .find(|file| file.path == selected_file)
            .ok_or("selected file is missing from descriptor list")?;
        fs::set_permissions(&selected_file, fs::Permissions::from_mode(0o400))?;

        let mut data = [0_u8; 6];
        assert!(file.read_exact_at(&mut data, 0).is_err());
        Ok(())
    }

    #[test]
    fn regular_directory_contents_remain_readable() -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("regular-tree")?;
        let selected = temp.join("selected");
        let nested = selected.join("nested");
        fs::create_dir_all(&nested)?;
        let selected_file = nested.join("shared.txt");
        fs::write(&selected_file, b"public")?;

        let mut files = construct_file_list(std::slice::from_ref(&selected))?;
        assert_eq!(files.len(), 3);
        let file = files
            .iter_mut()
            .find(|file| file.path == selected_file)
            .ok_or("selected file is missing from descriptor list")?;
        let mut data = [0_u8; 6];
        file.read_exact_at(&mut data, 0)?;
        assert_eq!(&data, b"public");
        Ok(())
    }

    #[test]
    fn hard_links_remain_regular_selected_files() -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("hard-link")?;
        let selected = temp.join("selected");
        fs::create_dir(&selected)?;
        let original = selected.join("original.txt");
        fs::write(&original, b"shared")?;
        fs::hard_link(&original, selected.join("alias.txt"))?;

        let files = construct_file_list(&[selected])?;
        assert_eq!(files.iter().filter(|file| !file.is_dir).count(), 2);
        Ok(())
    }

    #[test]
    fn as_bin_rejects_name_exceeding_520_bytes_without_panic() {
        let long_name = "a".repeat(522);
        let path = PathBuf::from(format!("/tmp/test/{}", long_name));
        let local_file = LocalFile {
            relative_root: PathBuf::from("/tmp/test"),
            path: path.clone(),
            handle: None,
            offset: AtomicU64::new(0),
            name: "test".to_string(),
            size: 0,
            last_write_time: UNIX_EPOCH,
            is_dir: false,
            read_only: false,
            hidden: false,
            system: false,
            archive: false,
            normal: true,
            perm: 0o644,
            source: None,
        };
        let res = local_file.as_bin();
        assert!(
            res.is_err(),
            "as_bin must reject path exceeding 520 bytes without panic"
        );
    }

    #[test]
    fn construct_file_list_rejects_deep_recursion() -> Result<(), Box<dyn std::error::Error>> {
        let temp = TestDir::new("deep-tree")?;
        let mut cur = temp.join("selected");
        fs::create_dir(&cur)?;
        // Create 66 nested directories (exceeds MAX_CLIPBOARD_RECURSION_DEPTH = 64)
        for i in 0..66 {
            cur = cur.join(format!("level_{}", i));
            fs::create_dir(&cur)?;
        }
        let res = construct_file_list(&[temp.join("selected")]);
        assert!(res.is_err(), "construct_file_list must reject directory tree deeper than MAX_CLIPBOARD_RECURSION_DEPTH");
        Ok(())
    }
}
