#![no_main]

#[path = "../../src/bin_reader.rs"]
mod bin_reader;

use libfuzzer_sys::fuzz_target;

const MAX_INPUT: usize = 64 * 1024;

fuzz_target!(|data: &[u8]| {
    if data.len() <= MAX_INPUT {
        let _ = bin_reader::validate_archive(data);
    }
});
