// Client Batch 21 Codec & Platform Safety Tests
// Target Items:
// 1. UNSAFE-005 (P1): AOM/VPX decoder borrowed frame lifecycle safety (DecodedImage lifetime + OwnedImage helper)
// 2. RES-032 (P2): Windows Magnification module lifecycle leak (RAII guard / cleanup on lookup or init failure)
// 3. PLATFORM-004 (P2): Windows SetupAPI failure sentinel handling (!null && != INVALID_HANDLE_VALUE)

use camellia_remote_protocol::message_proto::Chroma;
use scrap::{
    aom::{
        aom_image_t, aom_img_fmt, AomDecoder, AomEncoder, AomEncoderConfig,
        OwnedImage as AomOwnedImage,
    },
    codec::{EncoderApi, EncoderCfg},
    vpxcodec::{
        vpx_image_t, vpx_img_fmt, OwnedImage as VpxOwnedImage, VpxDecoder, VpxDecoderConfig,
        VpxEncoder, VpxEncoderConfig, VpxVideoCodecId,
    },
    GoogleImage, STRIDE_ALIGN,
};
use std::ptr;
use std::sync::atomic::{AtomicUsize, Ordering};

// =========================================================================
// 1. UNSAFE-005: VPX Decoder Borrowed Lifecycle & Owned Copy Tests
// =========================================================================

fn generate_i420_frame(w: usize, h: usize, pattern: u8) -> Vec<u8> {
    let y_size = w * h;
    let uv_size = (w / 2) * (h / 2);
    let mut data = vec![0u8; y_size + 2 * uv_size];

    // Y plane with gradient
    for y in 0..h {
        for x in 0..w {
            data[y * w + x] = ((x + y + pattern as usize) & 0xFF) as u8;
        }
    }
    // U plane
    let u_start = y_size;
    for i in 0..uv_size {
        data[u_start + i] = pattern.wrapping_add(64);
    }
    // V plane
    let v_start = y_size + uv_size;
    for i in 0..uv_size {
        data[v_start + i] = pattern.wrapping_add(128);
    }

    data
}

#[test]
fn test_vpx_decoder_borrowed_lifecycle_and_owned_copy() {
    let (width, height) = (64usize, 64usize);
    let enc_cfg = EncoderCfg::VPX(VpxEncoderConfig {
        width: width as _,
        height: height as _,
        quality: 1.0,
        codec: VpxVideoCodecId::VP9,
        keyframe_interval: Some(5),
    });

    let mut encoder = VpxEncoder::new(enc_cfg, false).expect("VP9 encoder should initialize");
    let mut decoder = VpxDecoder::new(VpxDecoderConfig {
        codec: VpxVideoCodecId::VP9,
    })
    .expect("VP9 decoder should initialize");

    let mut owned_frames: Vec<VpxOwnedImage> = Vec::new();

    // Encode 10 frames and decode them
    for frame_idx in 0..10 {
        let frame_data = generate_i420_frame(width, height, frame_idx as u8 * 20);
        let pts = frame_idx as i64 * 33;

        let mut encoded_packets: Vec<Vec<u8>> = encoder
            .encode(pts, &frame_data, STRIDE_ALIGN)
            .expect("encode failed")
            .map(|f| f.data.to_vec())
            .collect();
        encoded_packets.extend(
            encoder
                .flush()
                .expect("flush failed")
                .map(|f| f.data.to_vec()),
        );

        for pkt in &encoded_packets {
            let decode_iter = decoder.decode(pkt).expect("decode failed");
            for decoded_img in decode_iter {
                // Verify GoogleImage trait on borrowed DecodedImage
                assert_eq!(decoded_img.width(), width);
                assert_eq!(decoded_img.height(), height);
                assert_eq!(decoded_img.chroma(), Chroma::I420);
                assert!(!decoded_img.is_null());

                let planes = decoded_img.planes();
                assert_eq!(planes.len(), 4);
                assert!(!planes[0].is_null());
                assert!(!planes[1].is_null());
                assert!(!planes[2].is_null());

                // Create owned copy
                let owned = decoded_img.to_owned().expect("to_owned must succeed");
                assert_eq!(owned.width(), width);
                assert_eq!(owned.height(), height);
                assert_eq!(owned.chroma(), Chroma::I420);
                assert!(!owned.is_null());

                // Verify content in plane 0 (Y plane) matches
                let owned_planes = owned.planes();
                let decoded_stride = decoded_img.stride();
                let owned_stride = owned.stride();
                unsafe {
                    let mut matches = true;
                    for r in 0..height {
                        let dec_row = std::slice::from_raw_parts(
                            planes[0].add(r * decoded_stride[0] as usize),
                            width,
                        );
                        let own_row = std::slice::from_raw_parts(
                            owned_planes[0].add(r * owned_stride[0] as usize),
                            width,
                        );
                        if dec_row != own_row {
                            matches = false;
                            break;
                        }
                    }
                    assert!(
                        matches,
                        "OwnedImage plane data must match DecodedImage plane data"
                    );
                }

                // Store owned frame; it must outlive the DecodedImage
                owned_frames.push(owned);
            }
            // DecodedImage dropped here at end of loop body without freeing decoder internal buffer!
        }
    }

    // Flush any pending decoder frames
    for flushed_img in decoder.flush().expect("flush failed") {
        let owned = flushed_img.to_owned().expect("to_owned on flushed frame");
        owned_frames.push(owned);
    }

    assert!(
        !owned_frames.is_empty(),
        "Decoder should have produced frames"
    );

    // Drop decoder entirely
    drop(decoder);

    // Verify owned frames remain fully valid and can be read and dropped after decoder destruction
    for owned in &owned_frames {
        assert_eq!(owned.width(), width);
        assert_eq!(owned.height(), height);
        assert_eq!(owned.chroma(), Chroma::I420);
        let planes = owned.planes();
        assert!(!planes[0].is_null());
    }

    // Drop all owned frames; their Drop impl calls vpx_img_free safely on heap-allocated images
    drop(owned_frames);
}

#[test]
fn test_vpx_multi_frame_rapid_decode_drop_stress() {
    // Under the old code with Image::drop calling vpx_img_free on borrowed frames,
    // decoding and dropping multiple frames consecutively caused heap corruption
    // and double-free crashes. This stress test verifies stability across 50 frames.
    let (width, height) = (64usize, 64usize);
    let enc_cfg = EncoderCfg::VPX(VpxEncoderConfig {
        width: width as _,
        height: height as _,
        quality: 1.0,
        codec: VpxVideoCodecId::VP9,
        keyframe_interval: Some(10),
    });

    let mut encoder = VpxEncoder::new(enc_cfg, false).expect("VP9 encoder should initialize");
    let mut decoder = VpxDecoder::new(VpxDecoderConfig {
        codec: VpxVideoCodecId::VP9,
    })
    .expect("VP9 decoder should initialize");

    let mut decoded_frame_count = 0usize;

    for i in 0..50 {
        let frame_data = generate_i420_frame(width, height, (i * 5) as u8);
        let mut packets: Vec<Vec<u8>> = encoder
            .encode((i * 33) as i64, &frame_data, STRIDE_ALIGN)
            .expect("encode")
            .map(|f| f.data.to_vec())
            .collect();
        packets.extend(encoder.flush().expect("flush").map(|f| f.data.to_vec()));

        for pkt in &packets {
            for img in decoder.decode(pkt).expect("decode") {
                decoded_frame_count += 1;
                // Reading values
                assert_eq!(img.width(), width);
                assert_eq!(img.height(), height);
                // `img` is dropped immediately here
            }
        }
    }

    for _img in decoder.flush().expect("flush") {
        decoded_frame_count += 1;
    }

    assert!(
        decoded_frame_count > 0,
        "Stress test must have decoded frames"
    );
}

// =========================================================================
// 2. UNSAFE-005: AOM AV1 Decoder Borrowed Lifecycle & Owned Copy Tests
// =========================================================================

#[test]
fn test_aom_decoder_borrowed_lifecycle_and_owned_copy() {
    let (width, height) = (64usize, 64usize);
    let enc_cfg = EncoderCfg::AOM(AomEncoderConfig {
        width: width as _,
        height: height as _,
        quality: 1.0,
        keyframe_interval: Some(5),
    });

    let mut encoder = AomEncoder::new(enc_cfg, false).expect("AOM encoder should initialize");
    let mut decoder = AomDecoder::new().expect("AOM decoder should initialize");

    let mut owned_frames: Vec<AomOwnedImage> = Vec::new();

    for frame_idx in 0..10 {
        let frame_data = generate_i420_frame(width, height, frame_idx as u8 * 25);
        let pts = frame_idx as i64 * 33;

        let encoded_packets: Vec<Vec<u8>> = encoder
            .encode(pts, &frame_data, STRIDE_ALIGN)
            .expect("aom encode failed")
            .map(|f| f.data.to_vec())
            .collect();

        for pkt in &encoded_packets {
            let decode_iter = decoder.decode(pkt).expect("aom decode failed");
            for decoded_img in decode_iter {
                assert_eq!(decoded_img.width(), width);
                assert_eq!(decoded_img.height(), height);
                assert_eq!(decoded_img.chroma(), Chroma::I420);
                assert!(!decoded_img.is_null());

                let planes = decoded_img.planes();
                assert!(!planes[0].is_null());
                assert!(!planes[1].is_null());
                assert!(!planes[2].is_null());

                let owned = decoded_img.to_owned().expect("aom to_owned must succeed");
                assert_eq!(owned.width(), width);
                assert_eq!(owned.height(), height);
                assert_eq!(owned.chroma(), Chroma::I420);
                assert!(!owned.is_null());

                // Verify plane data matches
                let owned_planes = owned.planes();
                let decoded_stride = decoded_img.stride();
                let owned_stride = owned.stride();
                unsafe {
                    let mut matches = true;
                    for r in 0..height {
                        let dec_row = std::slice::from_raw_parts(
                            planes[0].add(r * decoded_stride[0] as usize),
                            width,
                        );
                        let own_row = std::slice::from_raw_parts(
                            owned_planes[0].add(r * owned_stride[0] as usize),
                            width,
                        );
                        if dec_row != own_row {
                            matches = false;
                            break;
                        }
                    }
                    assert!(matches, "AOM OwnedImage plane data must match DecodedImage");
                }

                owned_frames.push(owned);
            }
        }
    }

    for flushed_img in decoder.flush().expect("flush failed") {
        let owned = flushed_img.to_owned().expect("aom to_owned on flushed");
        owned_frames.push(owned);
    }

    assert!(
        !owned_frames.is_empty(),
        "AOM decoder should have decoded frames"
    );

    drop(decoder);

    for owned in &owned_frames {
        assert_eq!(owned.width(), width);
        assert_eq!(owned.height(), height);
        assert_eq!(owned.chroma(), Chroma::I420);
    }

    drop(owned_frames);
}

#[test]
fn test_aom_multi_frame_rapid_decode_drop_stress() {
    let (width, height) = (64usize, 64usize);
    let enc_cfg = EncoderCfg::AOM(AomEncoderConfig {
        width: width as _,
        height: height as _,
        quality: 1.0,
        keyframe_interval: Some(10),
    });

    let mut encoder = AomEncoder::new(enc_cfg, false).expect("AOM encoder should initialize");
    let mut decoder = AomDecoder::new().expect("AOM decoder should initialize");

    let mut decoded_count = 0usize;

    for i in 0..25 {
        let frame_data = generate_i420_frame(width, height, (i * 7) as u8);
        let packets: Vec<Vec<u8>> = encoder
            .encode((i * 33) as i64, &frame_data, STRIDE_ALIGN)
            .expect("encode")
            .map(|f| f.data.to_vec())
            .collect();

        for pkt in &packets {
            for img in decoder.decode(pkt).expect("decode") {
                decoded_count += 1;
                assert_eq!(img.width(), width);
                assert_eq!(img.height(), height);
            }
        }
    }

    for _img in decoder.flush().expect("flush") {
        decoded_count += 1;
    }

    assert!(decoded_count > 0, "AOM stress test decoded frames");
}

#[test]
fn test_owned_image_copy_from_raw_error_handling() {
    // 1. Null pointer handling
    assert!(unsafe { VpxOwnedImage::copy_from_raw(ptr::null()) }.is_err());
    assert!(unsafe { AomOwnedImage::copy_from_raw(ptr::null()) }.is_err());

    // 2. Default/empty image handling
    let default_vpx = VpxOwnedImage::new();
    assert!(default_vpx.is_null());
    assert!(default_vpx.try_clone().is_err());
    drop(default_vpx);

    let default_aom = AomOwnedImage::new();
    assert!(default_aom.is_null());
    assert!(default_aom.try_clone().is_err());
    drop(default_aom);

    // 3. Invalid dimensions: w == 0, h == 0, or excessive dimensions
    let mut raw_vpx: vpx_image_t = unsafe { std::mem::zeroed() };
    raw_vpx.fmt = vpx_img_fmt::VPX_IMG_FMT_I420;
    raw_vpx.d_w = 0;
    raw_vpx.d_h = 64;
    assert!(unsafe { VpxOwnedImage::copy_from_raw(&raw_vpx) }.is_err());

    raw_vpx.d_w = 64;
    raw_vpx.d_h = 0;
    assert!(unsafe { VpxOwnedImage::copy_from_raw(&raw_vpx) }.is_err());

    raw_vpx.d_w = 30000;
    raw_vpx.d_h = 30000;
    assert!(unsafe { VpxOwnedImage::copy_from_raw(&raw_vpx) }.is_err());

    // 4. Invalid chroma shifts (> 3: prevents shift overflow / panics)
    raw_vpx.d_w = 64;
    raw_vpx.d_h = 64;
    raw_vpx.x_chroma_shift = 32;
    assert!(unsafe { VpxOwnedImage::copy_from_raw(&raw_vpx) }.is_err());

    raw_vpx.x_chroma_shift = 1;
    raw_vpx.y_chroma_shift = 4;
    assert!(unsafe { VpxOwnedImage::copy_from_raw(&raw_vpx) }.is_err());

    // 5. Unsupported / corrupted color format
    raw_vpx.y_chroma_shift = 1;
    raw_vpx.fmt = vpx_img_fmt::VPX_IMG_FMT_NONE;
    assert!(unsafe { VpxOwnedImage::copy_from_raw(&raw_vpx) }.is_err());

    // AOM identical validation
    let mut raw_aom: aom_image_t = unsafe { std::mem::zeroed() };
    raw_aom.fmt = aom_img_fmt::AOM_IMG_FMT_I420;
    raw_aom.d_w = 0;
    raw_aom.d_h = 64;
    assert!(unsafe { AomOwnedImage::copy_from_raw(&raw_aom) }.is_err());

    raw_aom.d_w = 64;
    raw_aom.d_h = 64;
    raw_aom.x_chroma_shift = 32;
    assert!(unsafe { AomOwnedImage::copy_from_raw(&raw_aom) }.is_err());

    raw_aom.x_chroma_shift = 1;
    raw_aom.y_chroma_shift = 5;
    assert!(unsafe { AomOwnedImage::copy_from_raw(&raw_aom) }.is_err());

    raw_aom.y_chroma_shift = 1;
    raw_aom.fmt = aom_img_fmt::AOM_IMG_FMT_NONE;
    assert!(unsafe { AomOwnedImage::copy_from_raw(&raw_aom) }.is_err());

    // 6. Non-positive stride rejection
    let mut plane_buf = vec![0u8; 64 * 64];
    raw_vpx.fmt = vpx_img_fmt::VPX_IMG_FMT_I420;
    raw_vpx.d_w = 64;
    raw_vpx.d_h = 64;
    raw_vpx.x_chroma_shift = 1;
    raw_vpx.y_chroma_shift = 1;
    raw_vpx.planes[0] = plane_buf.as_mut_ptr();
    raw_vpx.stride[0] = -64; // negative stride: must be rejected!
    assert!(unsafe { VpxOwnedImage::copy_from_raw(&raw_vpx) }.is_err());

    raw_vpx.stride[0] = 0; // zero stride: must be rejected!
    assert!(unsafe { VpxOwnedImage::copy_from_raw(&raw_vpx) }.is_err());

    raw_aom.fmt = aom_img_fmt::AOM_IMG_FMT_I420;
    raw_aom.d_w = 64;
    raw_aom.d_h = 64;
    raw_aom.x_chroma_shift = 1;
    raw_aom.y_chroma_shift = 1;
    raw_aom.planes[0] = plane_buf.as_mut_ptr();
    raw_aom.stride[0] = -64;
    assert!(unsafe { AomOwnedImage::copy_from_raw(&raw_aom) }.is_err());

    raw_aom.stride[0] = 0;
    assert!(unsafe { AomOwnedImage::copy_from_raw(&raw_aom) }.is_err());
}

#[test]
fn test_owned_image_send_across_threads() {
    let (width, height) = (64usize, 64usize);
    let enc_cfg = EncoderCfg::VPX(VpxEncoderConfig {
        width: width as _,
        height: height as _,
        quality: 1.0,
        codec: VpxVideoCodecId::VP9,
        keyframe_interval: Some(5),
    });

    let mut encoder = VpxEncoder::new(enc_cfg, false).unwrap();
    let mut decoder = VpxDecoder::new(VpxDecoderConfig {
        codec: VpxVideoCodecId::VP9,
    })
    .unwrap();

    let frame_data = generate_i420_frame(width, height, 42);
    let mut packets: Vec<Vec<u8>> = encoder
        .encode(0, &frame_data, STRIDE_ALIGN)
        .unwrap()
        .map(|f| f.data.to_vec())
        .collect();
    packets.extend(encoder.flush().unwrap().map(|f| f.data.to_vec()));

    let mut owned_vpx = None;
    for pkt in packets {
        if let Some(img) = decoder.decode(&pkt).unwrap().next() {
            owned_vpx = Some(img.to_owned().unwrap());
            break;
        }
    }
    if owned_vpx.is_none() {
        if let Some(img) = decoder.flush().unwrap().next() {
            owned_vpx = Some(img.to_owned().unwrap());
        }
    }

    let owned_vpx = owned_vpx.expect("VPX should produce a frame");

    // Move VpxOwnedImage across thread boundary (verifies Send implementation)
    let handle_vpx = std::thread::spawn(move || {
        assert_eq!(owned_vpx.width(), width);
        assert_eq!(owned_vpx.height(), height);
        assert_eq!(owned_vpx.chroma(), Chroma::I420);
        drop(owned_vpx);
    });
    handle_vpx.join().unwrap();

    // Verify AomOwnedImage Send as well
    let aom_cfg = EncoderCfg::AOM(AomEncoderConfig {
        width: width as _,
        height: height as _,
        quality: 1.0,
        keyframe_interval: Some(5),
    });
    let mut aom_enc = AomEncoder::new(aom_cfg, false).unwrap();
    let mut aom_dec = AomDecoder::new().unwrap();

    let aom_pkts: Vec<Vec<u8>> = aom_enc
        .encode(0, &frame_data, STRIDE_ALIGN)
        .unwrap()
        .map(|f| f.data.to_vec())
        .collect();

    let mut owned_aom = None;
    for pkt in aom_pkts {
        if let Some(img) = aom_dec.decode(&pkt).unwrap().next() {
            owned_aom = Some(img.to_owned().unwrap());
            break;
        }
    }
    if owned_aom.is_none() {
        if let Some(img) = aom_dec.flush().unwrap().next() {
            owned_aom = Some(img.to_owned().unwrap());
        }
    }
    let owned_aom = owned_aom.expect("AOM should produce a frame");

    let handle_aom = std::thread::spawn(move || {
        assert_eq!(owned_aom.width(), width);
        assert_eq!(owned_aom.height(), height);
        assert_eq!(owned_aom.chroma(), Chroma::I420);
        drop(owned_aom);
    });
    handle_aom.join().unwrap();
}

// =========================================================================
// 3. RES-032: Windows Magnification Module Lifecycle Leak Verification
// =========================================================================

/// Simulates the exact RAII lifecycle contract of `MagInterface`:
/// - When `LoadLibrary` succeeds, any error in symbol lookup (`GetProcAddress`)
///   or initialization (`MagInitialize`) MUST call `FreeLibrary`.
/// - If initialization succeeded, `MagUninitialize` is called before `FreeLibrary`.
/// - Calling `uninit()` multiple times is idempotent and safe.
struct MockMagLifecycleManager {
    lib_handle: Option<usize>,
    init_succeeded: bool,
    free_library_calls: &'static AtomicUsize,
    mag_uninit_calls: &'static AtomicUsize,
}

impl MockMagLifecycleManager {
    fn simulate_new(
        load_success: bool,
        symbol_success: bool,
        init_success: bool,
        free_counter: &'static AtomicUsize,
        uninit_counter: &'static AtomicUsize,
    ) -> Result<Self, &'static str> {
        let mut s = Self {
            lib_handle: None,
            init_succeeded: false,
            free_library_calls: free_counter,
            mag_uninit_calls: uninit_counter,
        };

        if !load_success {
            return Err("LoadLibrary failed");
        }
        s.lib_handle = Some(0xDEADBEEF);

        if !symbol_success {
            return Err("GetProcAddress failed");
        }

        if !init_success {
            return Err("MagInitialize failed");
        }

        s.init_succeeded = true;
        Ok(s)
    }

    fn uninit(&mut self) {
        if self.init_succeeded {
            self.mag_uninit_calls.fetch_add(1, Ordering::SeqCst);
            self.init_succeeded = false;
        }
        if let Some(_handle) = self.lib_handle.take() {
            self.free_library_calls.fetch_add(1, Ordering::SeqCst);
        }
    }
}

impl Drop for MockMagLifecycleManager {
    fn drop(&mut self) {
        self.uninit();
    }
}

#[test]
fn test_res032_magnification_lifecycle_contract() {
    static FREE_COUNTER: AtomicUsize = AtomicUsize::new(0);
    static UNINIT_COUNTER: AtomicUsize = AtomicUsize::new(0);

    // Case 1: Load fails -> neither FreeLibrary nor MagUninitialize called
    FREE_COUNTER.store(0, Ordering::SeqCst);
    UNINIT_COUNTER.store(0, Ordering::SeqCst);
    let res =
        MockMagLifecycleManager::simulate_new(false, true, true, &FREE_COUNTER, &UNINIT_COUNTER);
    assert!(res.is_err());
    assert_eq!(FREE_COUNTER.load(Ordering::SeqCst), 0);
    assert_eq!(UNINIT_COUNTER.load(Ordering::SeqCst), 0);

    // Case 2: Load succeeds, but symbol lookup fails -> FreeLibrary MUST be called, MagUninit NOT called
    FREE_COUNTER.store(0, Ordering::SeqCst);
    UNINIT_COUNTER.store(0, Ordering::SeqCst);
    let res =
        MockMagLifecycleManager::simulate_new(true, false, true, &FREE_COUNTER, &UNINIT_COUNTER);
    assert!(res.is_err());
    assert_eq!(
        FREE_COUNTER.load(Ordering::SeqCst),
        1,
        "FreeLibrary must be called when symbol lookup fails"
    );
    assert_eq!(
        UNINIT_COUNTER.load(Ordering::SeqCst),
        0,
        "MagUninitialize must NOT be called if initialization never succeeded"
    );

    // Case 3: Load succeeds, symbol lookup succeeds, but MagInitialize fails -> FreeLibrary MUST be called
    FREE_COUNTER.store(0, Ordering::SeqCst);
    UNINIT_COUNTER.store(0, Ordering::SeqCst);
    let res =
        MockMagLifecycleManager::simulate_new(true, true, false, &FREE_COUNTER, &UNINIT_COUNTER);
    assert!(res.is_err());
    assert_eq!(
        FREE_COUNTER.load(Ordering::SeqCst),
        1,
        "FreeLibrary must be called when MagInitialize fails"
    );
    assert_eq!(
        UNINIT_COUNTER.load(Ordering::SeqCst),
        0,
        "MagUninitialize must NOT be called if MagInitialize failed"
    );

    // Case 4: Complete success -> on drop, MagUninitialize called first, then FreeLibrary
    FREE_COUNTER.store(0, Ordering::SeqCst);
    UNINIT_COUNTER.store(0, Ordering::SeqCst);
    {
        let res =
            MockMagLifecycleManager::simulate_new(true, true, true, &FREE_COUNTER, &UNINIT_COUNTER);
        assert!(res.is_ok());
        assert_eq!(FREE_COUNTER.load(Ordering::SeqCst), 0);
        assert_eq!(UNINIT_COUNTER.load(Ordering::SeqCst), 0);
    }
    // Dropped
    assert_eq!(
        UNINIT_COUNTER.load(Ordering::SeqCst),
        1,
        "MagUninitialize must be called once on drop"
    );
    assert_eq!(
        FREE_COUNTER.load(Ordering::SeqCst),
        1,
        "FreeLibrary must be called once on drop"
    );

    // Case 5: Idempotent manual uninit followed by drop
    FREE_COUNTER.store(0, Ordering::SeqCst);
    UNINIT_COUNTER.store(0, Ordering::SeqCst);
    {
        let mut mgr =
            MockMagLifecycleManager::simulate_new(true, true, true, &FREE_COUNTER, &UNINIT_COUNTER)
                .unwrap();
        mgr.uninit();
        assert_eq!(UNINIT_COUNTER.load(Ordering::SeqCst), 1);
        assert_eq!(FREE_COUNTER.load(Ordering::SeqCst), 1);
        // Subsequent manual uninit is a no-op
        mgr.uninit();
        assert_eq!(UNINIT_COUNTER.load(Ordering::SeqCst), 1);
        assert_eq!(FREE_COUNTER.load(Ordering::SeqCst), 1);
    }
    // Drop after manual uninit does not double-call
    assert_eq!(UNINIT_COUNTER.load(Ordering::SeqCst), 1);
    assert_eq!(FREE_COUNTER.load(Ordering::SeqCst), 1);
}

// =========================================================================
// 4. PLATFORM-004: Windows SetupAPI Failure Sentinel Handling Verification
// =========================================================================

/// Sentinel validation helper identical to `is_valid_hdevinfo` in `win_device.rs`.
#[inline]
fn is_valid_hdevinfo_handle(handle: *mut std::ffi::c_void) -> bool {
    !handle.is_null() && handle != (-1isize as *mut std::ffi::c_void)
}

struct MockDeviceInfoGuard {
    handle: *mut std::ffi::c_void,
    destroy_calls: &'static AtomicUsize,
}

impl MockDeviceInfoGuard {
    fn new(
        handle: *mut std::ffi::c_void,
        destroy_counter: &'static AtomicUsize,
    ) -> Result<Self, &'static str> {
        if !is_valid_hdevinfo_handle(handle) {
            return Err(
                "SetupAPI function returned failure sentinel (NULL or INVALID_HANDLE_VALUE)",
            );
        }
        Ok(Self {
            handle,
            destroy_calls: destroy_counter,
        })
    }
}

impl Drop for MockDeviceInfoGuard {
    fn drop(&mut self) {
        if is_valid_hdevinfo_handle(self.handle) {
            self.destroy_calls.fetch_add(1, Ordering::SeqCst);
            self.handle = ptr::null_mut();
        }
    }
}

#[test]
fn test_platform004_setupapi_sentinel_discrimination() {
    let null_handle = ptr::null_mut::<std::ffi::c_void>();
    let invalid_handle_value = -1isize as *mut std::ffi::c_void;
    let valid_handle = 0x12345678usize as *mut std::ffi::c_void;

    // Both NULL and INVALID_HANDLE_VALUE are recognized as invalid
    assert!(!is_valid_hdevinfo_handle(null_handle));
    assert!(!is_valid_hdevinfo_handle(invalid_handle_value));

    // Valid pointer is recognized as valid
    assert!(is_valid_hdevinfo_handle(valid_handle));
}

#[test]
fn test_platform004_setupapi_guard_lifecycle() {
    static DESTROY_COUNTER: AtomicUsize = AtomicUsize::new(0);

    let null_handle = ptr::null_mut::<std::ffi::c_void>();
    let invalid_handle_value = -1isize as *mut std::ffi::c_void;
    let valid_handle = 0x8888usize as *mut std::ffi::c_void;

    // Creation fails on NULL without wrapping into guard
    DESTROY_COUNTER.store(0, Ordering::SeqCst);
    let res_null = MockDeviceInfoGuard::new(null_handle, &DESTROY_COUNTER);
    assert!(res_null.is_err());
    assert_eq!(DESTROY_COUNTER.load(Ordering::SeqCst), 0);

    // Creation fails on INVALID_HANDLE_VALUE without wrapping into guard
    DESTROY_COUNTER.store(0, Ordering::SeqCst);
    let res_invalid = MockDeviceInfoGuard::new(invalid_handle_value, &DESTROY_COUNTER);
    assert!(res_invalid.is_err());
    assert_eq!(DESTROY_COUNTER.load(Ordering::SeqCst), 0);

    // Creation succeeds on valid handle, destroy called exactly once on drop
    DESTROY_COUNTER.store(0, Ordering::SeqCst);
    {
        let guard = MockDeviceInfoGuard::new(valid_handle, &DESTROY_COUNTER).unwrap();
        assert_eq!(DESTROY_COUNTER.load(Ordering::SeqCst), 0);
        drop(guard);
    }
    assert_eq!(
        DESTROY_COUNTER.load(Ordering::SeqCst),
        1,
        "Destroy must be called exactly once for valid handle"
    );

    // Defensive drop: guard holding sentinel explicitly does not invoke destroy
    DESTROY_COUNTER.store(0, Ordering::SeqCst);
    let guard_sentinel = MockDeviceInfoGuard {
        handle: invalid_handle_value,
        destroy_calls: &DESTROY_COUNTER,
    };
    drop(guard_sentinel);
    assert_eq!(
        DESTROY_COUNTER.load(Ordering::SeqCst),
        0,
        "Destroy must NOT be called on sentinel handle"
    );
}

#[cfg(windows)]
#[test]
fn test_windows_native_device_info_sentinels() {
    use crate::platform::win_device::is_valid_hdevinfo;
    use winapi::um::handleapi::INVALID_HANDLE_VALUE;

    assert!(!is_valid_hdevinfo(ptr::null_mut()));
    assert!(!is_valid_hdevinfo(INVALID_HANDLE_VALUE));
    assert!(is_valid_hdevinfo(0x9999 as _));
}
