use std::{
    env,
    path::{Path, PathBuf},
};

#[cfg(feature = "linux-pkg-config")]
fn link_pkg_config(name: &str) -> Vec<PathBuf> {
    let lib = pkg_config::probe_library(name)
        .expect(format!(
            "unable to find '{name}' development headers with pkg-config (feature linux-pkg-config is enabled).
            try installing '{name}-dev' from your system package manager.").as_str());

    lib.include_paths
}

fn link_vcpkg(mut path: PathBuf, name: &str) -> PathBuf {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    let mut target_arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap();
    if target_arch == "x86_64" {
        target_arch = "x64".to_owned();
    } else if target_arch == "aarch64" {
        target_arch = "arm64".to_owned();
    }
    let mut target = if target_os == "macos" && target_arch == "x64" {
        "x64-osx".to_owned()
    } else if target_os == "macos" && target_arch == "arm64" {
        "arm64-osx".to_owned()
    } else if target_os == "windows" {
        format!("{}-windows-static", target_arch)
    } else {
        format!("{}-{}", target_arch, target_os)
    };
    if target_arch == "x86" {
        target = target.replace("x64", "x86");
    }
    println!("cargo:info={}", target);
    path.push("installed");
    path.push(target);
    println!(
        "{}",
        format!(
            "cargo:rustc-link-lib=static={}",
            name.trim_start_matches("lib")
        )
    );
    println!(
        "{}",
        format!(
            "cargo:rustc-link-search={}",
            path.join("lib").to_str().unwrap()
        )
    );
    let include = path.join("include");
    println!("{}", format!("cargo:include={}", include.to_str().unwrap()));
    include
}

fn link_homebrew_m1(name: &str) -> PathBuf {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    let target_arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap();
    if target_os != "macos" || target_arch != "aarch64" {
        panic!("Couldn't find VCPKG_ROOT, also can't fallback to homebrew because it's only for macos aarch64.");
    }
    let mut path = PathBuf::from("/opt/homebrew/Cellar");
    path.push(name);
    let entries = if let Ok(dir) = std::fs::read_dir(&path) {
        dir
    } else {
        panic!("Could not find package in {}. Make sure your homebrew and package {} are all installed.", path.to_str().unwrap(),&name);
    };
    let mut directories = entries
        .into_iter()
        .filter(|x| x.is_ok())
        .map(|x| x.unwrap().path())
        .filter(|x| x.is_dir())
        .collect::<Vec<_>>();
    // Find the newest version.
    directories.sort_unstable();
    if directories.is_empty() {
        panic!(
            "There's no installed version of {} in /opt/homebrew/Cellar",
            name
        );
    }
    path.push(directories.pop().unwrap());
    // Link the library.
    println!(
        "{}",
        format!(
            "cargo:rustc-link-lib=static={}",
            name.trim_start_matches("lib")
        )
    );
    // Add the library path.
    println!(
        "{}",
        format!(
            "cargo:rustc-link-search={}",
            path.join("lib").to_str().unwrap()
        )
    );
    // Add the include path.
    let include = path.join("include");
    println!("{}", format!("cargo:include={}", include.to_str().unwrap()));
    include
}

fn find_package(name: &str) -> Vec<PathBuf> {
    #[cfg(feature = "linux-pkg-config")]
    {
        let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
        if target_os == "linux" {
            return link_pkg_config(name);
        }
    }

    if let Ok(vcpkg_root) = std::env::var("VCPKG_ROOT") {
        vec![link_vcpkg(vcpkg_root.into(), name)]
    } else {
        vec![link_homebrew_m1(name)]
    }
}

fn bindgen_builder() -> bindgen::Builder {
    let mut builder = bindgen::builder();
    let target = env::var("TARGET").unwrap_or_default();
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let target_arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    if target_os == "android" || target.contains("android") {
        let raw_api = env::var("CARGO_NDK_ANDROID_PLATFORM")
            .or_else(|_| env::var("CARGO_NDK_PLATFORM"))
            .or_else(|_| env::var("ANDROID_PLATFORM"))
            .or_else(|_| env::var("MIN_SDK_VERSION"))
            .unwrap_or_else(|_| "26".to_string());
        let trimmed_api = raw_api.trim_start_matches("android-");
        let api_level = if trimmed_api.chars().all(|c| c.is_ascii_digit()) && !trimmed_api.is_empty() {
            trimmed_api.to_string()
        } else {
            "26".to_string()
        };
        let versioned_target = if target.starts_with("aarch64") || target_arch == "aarch64" {
            format!("aarch64-linux-android{}", api_level)
        } else if target.starts_with("armv7") || target_arch == "arm" {
            format!("armv7a-linux-androideabi{}", api_level)
        } else if target.starts_with("x86_64") || target_arch == "x86_64" {
            format!("x86_64-linux-android{}", api_level)
        } else if target.starts_with("i686") || target_arch == "x86" {
            format!("i686-linux-android{}", api_level)
        } else {
            format!("{}-linux-android{}", target_arch, api_level)
        };
        builder = builder
            .clang_arg(format!("--target={}", versioned_target))
            .clang_arg(format!("-D__ANDROID_API__={}", api_level));
    }
    builder
}

fn generate_bindings(ffi_header: &Path, include_paths: &[PathBuf], ffi_rs: &Path) {
    #[derive(Debug)]
    struct ParseCallbacks;
    impl bindgen::callbacks::ParseCallbacks for ParseCallbacks {
        fn int_macro(&self, name: &str, _value: i64) -> Option<bindgen::callbacks::IntKind> {
            if name.starts_with("OPUS") {
                Some(bindgen::callbacks::IntKind::Int)
            } else {
                None
            }
        }
    }
    let mut b = bindgen_builder()
        .header(ffi_header.to_str().unwrap())
        .parse_callbacks(Box::new(ParseCallbacks))
        .generate_comments(false);

    for dir in include_paths {
        b = b.clang_arg(format!("-I{}", dir.display()));
    }

    b.generate().unwrap().write_to_file(ffi_rs).unwrap();
}

fn gen_opus() {
    let includes = find_package("opus");
    let src_dir = env::var_os("CARGO_MANIFEST_DIR").unwrap();
    let src_dir = Path::new(&src_dir);
    let out_dir = env::var_os("OUT_DIR").unwrap();
    let out_dir = Path::new(&out_dir);

    let ffi_header = src_dir.join("opus_ffi.h");
    println!("rerun-if-changed={}", ffi_header.display());
    for dir in &includes {
        println!("rerun-if-changed={}", dir.display());
    }

    let ffi_rs = out_dir.join("opus_ffi.rs");
    generate_bindings(&ffi_header, &includes, &ffi_rs);
}

fn main() {
    gen_opus()
}
