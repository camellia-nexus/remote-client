// test_batch55_android_dependency_and_protobuf_contracts.rs
//
// Verification suite for Batch 55 (PROV-005, DEP-003).

use std::fs;
use std::path::PathBuf;

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_prov005_android_jitpack_and_verification_metadata_contracts() {
    let root = get_client_root();
    let root_gradle = fs::read_to_string(root.join("flutter/android/build.gradle"))
        .expect("Failed to read flutter/android/build.gradle");

    // 1. Content filtering on JitPack
    assert!(
        root_gradle.contains("https://jitpack.io"),
        "PROV-005: JitPack repository declaration must be present"
    );
    assert!(
        root_gradle.contains("includeGroupByRegex \"com\\\\.github\\\\..*\""),
        "PROV-005: JitPack repository must enforce content filtering for com.github.*"
    );

    // 2. Gradle verification metadata
    let verification_metadata =
        fs::read_to_string(root.join("flutter/android/gradle/verification-metadata.xml"))
            .expect("Failed to read verification-metadata.xml");

    assert!(
        verification_metadata.contains("<verify-metadata>true</verify-metadata>"),
        "PROV-005: verification-metadata.xml must enable verify-metadata"
    );
    assert!(
        verification_metadata.contains("name=\"protobuf-javalite\" version=\"3.25.5\""),
        "PROV-005: verification-metadata.xml must pin protobuf-javalite 3.25.5"
    );
    assert!(
        verification_metadata.contains("name=\"XXPermissions\" version=\"18.5\""),
        "PROV-005: verification-metadata.xml must pin XXPermissions 18.5"
    );
    assert!(
        verification_metadata.contains("name=\"protoc\" version=\"3.25.5\""),
        "PROV-005: verification-metadata.xml must pin protoc 3.25.5"
    );
}

#[test]
fn test_dep003_android_protobuf_upgrade_and_unknown_fields_contracts() {
    let root = get_client_root();
    let app_gradle = fs::read_to_string(root.join("flutter/android/app/build.gradle"))
        .expect("Failed to read flutter/android/app/build.gradle");

    // 1. Protobuf version upgrade: 3.20.1 -> 3.25.5
    assert!(
        !app_gradle.contains("protobuf-javalite:3.20.1"),
        "DEP-003: app/build.gradle must not use vulnerable protobuf-javalite 3.20.1"
    );
    assert!(
        !app_gradle.contains("protoc:3.20.1"),
        "DEP-003: app/build.gradle must not use protoc 3.20.1"
    );
    assert!(
        app_gradle.contains("com.google.protobuf:protobuf-javalite:3.25.5"),
        "DEP-003: app/build.gradle must declare protobuf-javalite 3.25.5"
    );
    assert!(
        app_gradle.contains("com.google.protobuf:protoc:3.25.5"),
        "DEP-003: app/build.gradle must declare protoc 3.25.5"
    );

    // 2. Unknown fields clearing in connection.rs
    let connection_rs = fs::read_to_string(root.join("src/server/connection.rs"))
        .expect("Failed to read src/server/connection.rs");
    let key_event_idx = connection_rs.find("call_main_service_key_event(&data)");
    assert!(
        key_event_idx.is_some(),
        "DEP-003: call_main_service_key_event not found"
    );
    let idx = key_event_idx.unwrap();
    let surrounding = &connection_rs[idx.saturating_sub(400)..idx];
    assert!(
        surrounding.contains("special_fields.clear()"),
        "DEP-003: KeyEvent must clear special_fields before serializing to JNI"
    );

    // 3. Unknown fields clearing in clipboard.rs
    let clipboard_rs =
        fs::read_to_string(root.join("src/clipboard.rs")).expect("Failed to read src/clipboard.rs");
    assert!(
        clipboard_rs.contains("multi_clips.special_fields.clear();"),
        "DEP-003: multi_clips must clear special_fields before serializing to JNI"
    );
    assert!(
        clipboard_rs.contains("mcb.special_fields.clear();"),
        "DEP-003: mcb must clear special_fields before serializing to JNI"
    );
}
