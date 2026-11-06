use std::{
    collections::HashMap,
    ops::{Deref, DerefMut},
    sync::{Arc, Mutex},
    time::Instant,
};

#[cfg(feature = "hwcodec")]
use crate::hwcodec::*;
#[cfg(feature = "mediacodec")]
use crate::mediacodec::{MediaCodecDecoder, H264_DECODER_SUPPORT, H265_DECODER_SUPPORT};
#[cfg(feature = "vram")]
use crate::vram::*;
use crate::{
    aom::{AomDecoder, AomEncoder, AomEncoderConfig},
    common::GoogleImage,
    vpxcodec::{VpxDecoder, VpxDecoderConfig, VpxEncoder, VpxEncoderConfig, VpxVideoCodecId},
    CodecFormat, EncodeInput, EncodeYuvFormat, ImageRgb, ImageTexture,
};

#[cfg(any(
    feature = "hwcodec",
    feature = "mediacodec",
    feature = "vram",
    target_os = "windows"
))]
use camellia_remote_protocol::config::option2bool;
use camellia_remote_protocol::{
    anyhow::anyhow,
    bail,
    config::{Config, PeerConfig},
    lazy_static, log,
    message_proto::{
        supported_decoding::PreferCodec, video_frame, Chroma, CodecAbility, EncodedVideoFrames,
        SupportedDecoding, SupportedEncoding, VideoFrame,
    },
    sysinfo::System,
    ResultType,
};

lazy_static::lazy_static! {
    static ref PEER_DECODINGS: Arc<Mutex<HashMap<i32, SupportedDecoding>>> = Default::default();
    static ref ENCODE_CODEC_FORMAT: Arc<Mutex<CodecFormat>> = Arc::new(Mutex::new(CodecFormat::VP9));
    static ref THREAD_LOG_TIME: Arc<Mutex<Option<Instant>>> = Arc::new(Mutex::new(None));
    static ref USABLE_ENCODING: Arc<Mutex<Option<SupportedEncoding>>> = Arc::new(Mutex::new(None));
}

pub const ENCODE_NEED_SWITCH: &'static str = "ENCODE_NEED_SWITCH";

#[derive(Debug, Clone)]
pub enum EncoderCfg {
    VPX(VpxEncoderConfig),
    AOM(AomEncoderConfig),
    #[cfg(feature = "hwcodec")]
    HWRAM(HwRamEncoderConfig),
    #[cfg(feature = "vram")]
    VRAM(VRamEncoderConfig),
}

pub trait EncoderApi {
    fn new(cfg: EncoderCfg, i444: bool) -> ResultType<Self>
    where
        Self: Sized;

    fn encode_to_message(&mut self, frame: EncodeInput, ms: i64) -> ResultType<VideoFrame>;

    fn yuvfmt(&self) -> EncodeYuvFormat;

    #[cfg(feature = "vram")]
    fn input_texture(&self) -> bool;

    fn set_quality(&mut self, ratio: f32) -> ResultType<()>;

    fn bitrate(&self) -> u32;

    fn support_changing_quality(&self) -> bool;

    fn latency_free(&self) -> bool;

    fn is_hardware(&self) -> bool;

    fn disable(&self);
}

pub struct Encoder {
    pub codec: Box<dyn EncoderApi>,
}

impl Deref for Encoder {
    type Target = Box<dyn EncoderApi>;

    fn deref(&self) -> &Self::Target {
        &self.codec
    }
}

impl DerefMut for Encoder {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.codec
    }
}

pub struct Decoder {
    vp8: Option<VpxDecoder>,
    vp9: Option<VpxDecoder>,
    av1: Option<AomDecoder>,
    #[cfg(feature = "hwcodec")]
    h264_ram: Option<HwRamDecoder>,
    #[cfg(feature = "hwcodec")]
    h265_ram: Option<HwRamDecoder>,
    #[cfg(feature = "vram")]
    h264_vram: Option<VRamDecoder>,
    #[cfg(feature = "vram")]
    h265_vram: Option<VRamDecoder>,
    #[cfg(feature = "mediacodec")]
    h264_media_codec: MediaCodecDecoder,
    #[cfg(feature = "mediacodec")]
    h265_media_codec: MediaCodecDecoder,
    format: CodecFormat,
    valid: bool,
    #[cfg(feature = "hwcodec")]
    i420: Vec<u8>,
}

#[derive(Debug, Clone)]
pub enum EncodingUpdate {
    Update(i32, SupportedDecoding),
    Remove(i32),
    NewOnlyVP9(i32),
    Check,
}

impl Encoder {
    pub fn new(config: EncoderCfg, i444: bool) -> ResultType<Encoder> {
        log::info!("new encoder: {config:?}, i444: {i444}");
        match config {
            EncoderCfg::VPX(_) => Ok(Encoder {
                codec: Box::new(VpxEncoder::new(config, i444)?),
            }),
            EncoderCfg::AOM(_) => Ok(Encoder {
                codec: Box::new(AomEncoder::new(config, i444)?),
            }),

            #[cfg(feature = "hwcodec")]
            EncoderCfg::HWRAM(_) => match HwRamEncoder::new(config, i444) {
                Ok(hw) => Ok(Encoder {
                    codec: Box::new(hw),
                }),
                Err(e) => {
                    log::error!("new hw encoder failed: {e:?}, clear config");
                    HwCodecConfig::clear(false, true);
                    *ENCODE_CODEC_FORMAT.lock().unwrap() = CodecFormat::VP9;
                    Err(e)
                }
            },
            #[cfg(feature = "vram")]
            EncoderCfg::VRAM(_) => match VRamEncoder::new(config, i444) {
                Ok(tex) => Ok(Encoder {
                    codec: Box::new(tex),
                }),
                Err(e) => {
                    log::error!("new vram encoder failed: {e:?}, clear config");
                    HwCodecConfig::clear(true, true);
                    *ENCODE_CODEC_FORMAT.lock().unwrap() = CodecFormat::VP9;
                    Err(e)
                }
            },
        }
    }

    pub fn update(update: EncodingUpdate) {
        log::info!("update:{:?}", update);
        let mut decodings = PEER_DECODINGS.lock().unwrap();
        match update {
            EncodingUpdate::Update(id, decoding) => {
                decodings.insert(id, decoding);
            }
            EncodingUpdate::Remove(id) => {
                decodings.remove(&id);
            }
            EncodingUpdate::NewOnlyVP9(id) => {
                decodings.insert(
                    id,
                    SupportedDecoding {
                        ability_vp9: 1,
                        ..Default::default()
                    },
                );
            }
            EncodingUpdate::Check => {}
        }

        let vp8_useable = decodings.len() > 0 && decodings.iter().all(|(_, s)| s.ability_vp8 > 0);
        let av1_useable = decodings.len() > 0
            && decodings.iter().all(|(_, s)| s.ability_av1 > 0)
            && !disable_av1();
        let _all_support_h264_decoding =
            decodings.len() > 0 && decodings.iter().all(|(_, s)| s.ability_h264 > 0);
        let _all_support_h265_decoding =
            decodings.len() > 0 && decodings.iter().all(|(_, s)| s.ability_h265 > 0);
        #[allow(unused_mut)]
        let mut h264vram_encoding = false;
        #[allow(unused_mut)]
        let mut h265vram_encoding = false;
        #[cfg(feature = "vram")]
        if enable_vram_option(true) {
            if _all_support_h264_decoding {
                if VRamEncoder::available(CodecFormat::H264).len() > 0 {
                    h264vram_encoding = true;
                }
            }
            if _all_support_h265_decoding {
                if VRamEncoder::available(CodecFormat::H265).len() > 0 {
                    h265vram_encoding = true;
                }
            }
        }
        #[allow(unused_mut)]
        let mut h264hw_encoding: Option<String> = None;
        #[allow(unused_mut)]
        let mut h265hw_encoding: Option<String> = None;
        #[cfg(feature = "hwcodec")]
        if enable_hwcodec_option() {
            if _all_support_h264_decoding {
                h264hw_encoding =
                    HwRamEncoder::try_get(CodecFormat::H264).map_or(None, |c| Some(c.name));
            }
            if _all_support_h265_decoding {
                h265hw_encoding =
                    HwRamEncoder::try_get(CodecFormat::H265).map_or(None, |c| Some(c.name));
            }
        }
        let h264_useable =
            _all_support_h264_decoding && (h264vram_encoding || h264hw_encoding.is_some());
        let h265_useable =
            _all_support_h265_decoding && (h265vram_encoding || h265hw_encoding.is_some());
        let mut format = ENCODE_CODEC_FORMAT.lock().unwrap();
        let preferences: Vec<_> = decodings
            .iter()
            .filter(|(_, s)| {
                s.prefer == PreferCodec::VP9.into()
                    || s.prefer == PreferCodec::VP8.into() && vp8_useable
                    || s.prefer == PreferCodec::AV1.into() && av1_useable
                    || s.prefer == PreferCodec::H264.into() && h264_useable
                    || s.prefer == PreferCodec::H265.into() && h265_useable
            })
            .map(|(_, s)| s.prefer)
            .collect();
        *USABLE_ENCODING.lock().unwrap() = Some(SupportedEncoding {
            vp8: vp8_useable,
            av1: av1_useable,
            h264: h264_useable,
            h265: h265_useable,
            ..Default::default()
        });
        // find the most frequent preference
        let mut counts = Vec::new();
        for pref in &preferences {
            match counts.iter_mut().find(|(p, _)| p == pref) {
                Some((_, count)) => *count += 1,
                None => counts.push((pref.clone(), 1)),
            }
        }
        let max_count = counts.iter().map(|(_, count)| *count).max().unwrap_or(0);
        let (most_frequent, _) = counts
            .into_iter()
            .find(|(_, count)| *count == max_count)
            .unwrap_or((PreferCodec::Auto.into(), 0));
        let preference = most_frequent.enum_value_or(PreferCodec::Auto);

        // auto: h265 > h264 > av1/vp9/vp8
        let av1_test =
            Config::get_option(camellia_remote_protocol::config::keys::OPTION_AV1_TEST) != "N";
        let mut auto_codec = if av1_useable && av1_test {
            CodecFormat::AV1
        } else {
            CodecFormat::VP9
        };
        if h264_useable {
            auto_codec = CodecFormat::H264;
        }
        if h265_useable {
            auto_codec = CodecFormat::H265;
        }
        if auto_codec == CodecFormat::VP9 || auto_codec == CodecFormat::AV1 {
            let mut system = System::new();
            system.refresh_memory();
            if vp8_useable && system.total_memory() <= 4 * 1024 * 1024 * 1024 {
                // 4 Gb
                auto_codec = CodecFormat::VP8
            }
        }

        *format = match preference {
            PreferCodec::VP8 => CodecFormat::VP8,
            PreferCodec::VP9 => CodecFormat::VP9,
            PreferCodec::AV1 => CodecFormat::AV1,
            PreferCodec::H264 => {
                if h264vram_encoding || h264hw_encoding.is_some() {
                    CodecFormat::H264
                } else {
                    auto_codec
                }
            }
            PreferCodec::H265 => {
                if h265vram_encoding || h265hw_encoding.is_some() {
                    CodecFormat::H265
                } else {
                    auto_codec
                }
            }
            PreferCodec::Auto => auto_codec,
        };
        if decodings.len() > 0 {
            log::info!(
                "usable: vp8={vp8_useable}, av1={av1_useable}, h264={h264_useable}, h265={h265_useable}",
            );
            log::info!(
                "connection count: {}, used preference: {:?}, encoder: {:?}",
                decodings.len(),
                preference,
                *format
            )
        }
    }

    #[inline]
    pub fn negotiated_codec() -> CodecFormat {
        ENCODE_CODEC_FORMAT.lock().unwrap().clone()
    }

    pub fn supported_encoding() -> SupportedEncoding {
        #[allow(unused_mut)]
        let mut encoding = SupportedEncoding {
            vp8: true,
            av1: !disable_av1(),
            i444: Some(CodecAbility {
                vp9: true,
                av1: true,
                ..Default::default()
            })
            .into(),
            ..Default::default()
        };
        #[cfg(feature = "hwcodec")]
        if enable_hwcodec_option() {
            encoding.h264 |= HwRamEncoder::try_get(CodecFormat::H264).is_some();
            encoding.h265 |= HwRamEncoder::try_get(CodecFormat::H265).is_some();
        }
        #[cfg(feature = "vram")]
        if enable_vram_option(true) {
            encoding.h264 |= VRamEncoder::available(CodecFormat::H264).len() > 0;
            encoding.h265 |= VRamEncoder::available(CodecFormat::H265).len() > 0;
        }
        encoding
    }

    pub fn usable_encoding() -> Option<SupportedEncoding> {
        USABLE_ENCODING.lock().unwrap().clone()
    }

    pub fn set_fallback(config: &EncoderCfg) {
        let format = match config {
            EncoderCfg::VPX(vpx) => match vpx.codec {
                VpxVideoCodecId::VP8 => CodecFormat::VP8,
                VpxVideoCodecId::VP9 => CodecFormat::VP9,
            },
            EncoderCfg::AOM(_) => CodecFormat::AV1,
            #[cfg(feature = "hwcodec")]
            EncoderCfg::HWRAM(hw) => {
                let name = hw.name.to_lowercase();
                if name.contains("vp8") {
                    CodecFormat::VP8
                } else if name.contains("vp9") {
                    CodecFormat::VP9
                } else if name.contains("av1") {
                    CodecFormat::AV1
                } else if name.contains("h264") {
                    CodecFormat::H264
                } else {
                    CodecFormat::H265
                }
            }
            #[cfg(feature = "vram")]
            EncoderCfg::VRAM(vram) => match vram.feature.data_format {
                hwcodec::common::DataFormat::H264 => CodecFormat::H264,
                hwcodec::common::DataFormat::H265 => CodecFormat::H265,
                _ => {
                    log::error!(
                        "should not reach here, vram not support {:?}",
                        vram.feature.data_format
                    );
                    return;
                }
            },
        };
        let current = ENCODE_CODEC_FORMAT.lock().unwrap().clone();
        if current != format {
            log::info!("codec fallback: {:?} -> {:?}", current, format);
            *ENCODE_CODEC_FORMAT.lock().unwrap() = format;
        }
    }

    pub fn use_i444(config: &EncoderCfg) -> bool {
        let decodings = PEER_DECODINGS.lock().unwrap().clone();
        let prefer_i444 = decodings
            .iter()
            .all(|d| d.1.prefer_chroma == Chroma::I444.into());
        let i444_useable = match config {
            EncoderCfg::VPX(vpx) => match vpx.codec {
                VpxVideoCodecId::VP8 => false,
                VpxVideoCodecId::VP9 => decodings.iter().all(|d| d.1.i444.vp9),
            },
            EncoderCfg::AOM(_) => decodings.iter().all(|d| d.1.i444.av1),
            #[cfg(feature = "hwcodec")]
            EncoderCfg::HWRAM(_) => false,
            #[cfg(feature = "vram")]
            EncoderCfg::VRAM(_) => false,
        };
        prefer_i444 && i444_useable && !decodings.is_empty()
    }
}

impl Decoder {
    pub fn supported_decodings(
        id_for_perfer: Option<&str>,
        _use_texture_render: bool,
        _luid: Option<i64>,
        mark_unsupported: &Vec<CodecFormat>,
    ) -> SupportedDecoding {
        let (prefer, prefer_chroma) = Self::preference(id_for_perfer);

        #[allow(unused_mut)]
        let mut decoding = SupportedDecoding {
            ability_vp8: 1,
            ability_vp9: 1,
            ability_av1: if disable_av1() { 0 } else { 1 },
            i444: Some(CodecAbility {
                vp9: true,
                av1: true,
                ..Default::default()
            })
            .into(),
            prefer: prefer.into(),
            prefer_chroma: prefer_chroma.into(),
            ..Default::default()
        };
        #[cfg(feature = "hwcodec")]
        {
            decoding.ability_h264 |= if HwRamDecoder::try_get(CodecFormat::H264).is_some() {
                1
            } else {
                0
            };
            decoding.ability_h265 |= if HwRamDecoder::try_get(CodecFormat::H265).is_some() {
                1
            } else {
                0
            };
        }
        #[cfg(feature = "vram")]
        if enable_vram_option(false) && _use_texture_render {
            decoding.ability_h264 |= if VRamDecoder::available(CodecFormat::H264, _luid).len() > 0 {
                1
            } else {
                0
            };
            decoding.ability_h265 |= if VRamDecoder::available(CodecFormat::H265, _luid).len() > 0 {
                1
            } else {
                0
            };
        }
        #[cfg(feature = "mediacodec")]
        if enable_hwcodec_option() {
            decoding.ability_h264 =
                if H264_DECODER_SUPPORT.load(std::sync::atomic::Ordering::SeqCst) {
                    1
                } else {
                    0
                };
            decoding.ability_h265 =
                if H265_DECODER_SUPPORT.load(std::sync::atomic::Ordering::SeqCst) {
                    1
                } else {
                    0
                };
        }
        for unsupported in mark_unsupported {
            match unsupported {
                CodecFormat::VP8 => decoding.ability_vp8 = 0,
                CodecFormat::VP9 => decoding.ability_vp9 = 0,
                CodecFormat::AV1 => decoding.ability_av1 = 0,
                CodecFormat::H264 => decoding.ability_h264 = 0,
                CodecFormat::H265 => decoding.ability_h265 = 0,
                _ => {}
            }
        }
        decoding
    }

    pub fn new(format: CodecFormat, _luid: Option<i64>) -> Decoder {
        log::info!("try create new decoder, format: {format:?}, _luid: {_luid:?}");
        let (mut vp8, mut vp9, mut av1) = (None, None, None);
        #[cfg(feature = "hwcodec")]
        let (mut h264_ram, mut h265_ram) = (None, None);
        #[cfg(feature = "vram")]
        let (mut h264_vram, mut h265_vram) = (None, None);
        #[cfg(feature = "mediacodec")]
        let (mut h264_media_codec, mut h265_media_codec) = (None, None);
        let mut valid = false;

        match format {
            CodecFormat::VP8 => {
                match VpxDecoder::new(VpxDecoderConfig {
                    codec: VpxVideoCodecId::VP8,
                }) {
                    Ok(v) => vp8 = Some(v),
                    Err(e) => log::error!("create VP8 decoder failed: {}", e),
                }
                valid = vp8.is_some();
            }
            CodecFormat::VP9 => {
                match VpxDecoder::new(VpxDecoderConfig {
                    codec: VpxVideoCodecId::VP9,
                }) {
                    Ok(v) => vp9 = Some(v),
                    Err(e) => log::error!("create VP9 decoder failed: {}", e),
                }
                valid = vp9.is_some();
            }
            CodecFormat::AV1 => {
                match AomDecoder::new() {
                    Ok(v) => av1 = Some(v),
                    Err(e) => log::error!("create AV1 decoder failed: {}", e),
                }
                valid = av1.is_some();
            }
            CodecFormat::H264 => {
                #[cfg(feature = "vram")]
                if !valid && enable_vram_option(false) && _luid.clone().unwrap_or_default() != 0 {
                    match VRamDecoder::new(format, _luid) {
                        Ok(v) => h264_vram = Some(v),
                        Err(e) => log::error!("create H264 vram decoder failed: {}", e),
                    }
                    valid = h264_vram.is_some();
                }
                #[cfg(feature = "hwcodec")]
                if !valid {
                    match HwRamDecoder::new(format) {
                        Ok(v) => h264_ram = Some(v),
                        Err(e) => log::error!("create H264 ram decoder failed: {}", e),
                    }
                    valid = h264_ram.is_some();
                }
                #[cfg(feature = "mediacodec")]
                if !valid && enable_hwcodec_option() {
                    h264_media_codec = MediaCodecDecoder::new(format);
                    if h264_media_codec.is_none() {
                        log::error!("create H264 media codec decoder failed");
                    }
                    valid = h264_media_codec.is_some();
                }
            }
            CodecFormat::H265 => {
                #[cfg(feature = "vram")]
                if !valid && enable_vram_option(false) && _luid.clone().unwrap_or_default() != 0 {
                    match VRamDecoder::new(format, _luid) {
                        Ok(v) => h265_vram = Some(v),
                        Err(e) => log::error!("create H265 vram decoder failed: {}", e),
                    }
                    valid = h265_vram.is_some();
                }
                #[cfg(feature = "hwcodec")]
                if !valid {
                    match HwRamDecoder::new(format) {
                        Ok(v) => h265_ram = Some(v),
                        Err(e) => log::error!("create H265 ram decoder failed: {}", e),
                    }
                    valid = h265_ram.is_some();
                }
                #[cfg(feature = "mediacodec")]
                if !valid && enable_hwcodec_option() {
                    h265_media_codec = MediaCodecDecoder::new(format);
                    if h265_media_codec.is_none() {
                        log::error!("create H265 media codec decoder failed");
                    }
                    valid = h265_media_codec.is_some();
                }
            }
            CodecFormat::Unknown => {
                log::error!("unknown codec format, cannot create decoder");
            }
        }
        if !valid {
            log::error!("failed to create {format:?} decoder");
        } else {
            log::info!("create {format:?} decoder success");
        }
        Decoder {
            vp8,
            vp9,
            av1,
            #[cfg(feature = "hwcodec")]
            h264_ram,
            #[cfg(feature = "hwcodec")]
            h265_ram,
            #[cfg(feature = "vram")]
            h264_vram,
            #[cfg(feature = "vram")]
            h265_vram,
            #[cfg(feature = "mediacodec")]
            h264_media_codec,
            #[cfg(feature = "mediacodec")]
            h265_media_codec,
            format,
            valid,
            #[cfg(feature = "hwcodec")]
            i420: vec![],
        }
    }

    pub fn format(&self) -> CodecFormat {
        self.format
    }

    pub fn valid(&self) -> bool {
        self.valid
    }

    // rgb [in/out] fmt and stride must be set in ImageRgb
    pub fn handle_video_frame(
        &mut self,
        frame: &video_frame::Union,
        rgb: &mut ImageRgb,
        _texture: &mut ImageTexture,
        _pixelbuffer: &mut bool,
        chroma: &mut Option<Chroma>,
    ) -> ResultType<bool> {
        match frame {
            video_frame::Union::Vp8s(vp8s) => {
                if let Some(vp8) = &mut self.vp8 {
                    Decoder::handle_vpxs_video_frame(vp8, vp8s, rgb, chroma)
                } else {
                    bail!("vp8 decoder not available");
                }
            }
            video_frame::Union::Vp9s(vp9s) => {
                if let Some(vp9) = &mut self.vp9 {
                    Decoder::handle_vpxs_video_frame(vp9, vp9s, rgb, chroma)
                } else {
                    bail!("vp9 decoder not available");
                }
            }
            video_frame::Union::Av1s(av1s) => {
                if let Some(av1) = &mut self.av1 {
                    Decoder::handle_av1s_video_frame(av1, av1s, rgb, chroma)
                } else {
                    bail!("av1 decoder not available");
                }
            }
            #[cfg(any(feature = "hwcodec", feature = "vram"))]
            video_frame::Union::H264s(h264s) => {
                *chroma = Some(Chroma::I420);
                #[cfg(feature = "vram")]
                if let Some(decoder) = &mut self.h264_vram {
                    *_pixelbuffer = false;
                    return Decoder::handle_vram_video_frame(decoder, h264s, _texture);
                }
                #[cfg(feature = "hwcodec")]
                if let Some(decoder) = &mut self.h264_ram {
                    return Decoder::handle_hwram_video_frame(decoder, h264s, rgb, &mut self.i420);
                }
                Err(anyhow!("don't support h264!"))
            }
            #[cfg(any(feature = "hwcodec", feature = "vram"))]
            video_frame::Union::H265s(h265s) => {
                *chroma = Some(Chroma::I420);
                #[cfg(feature = "vram")]
                if let Some(decoder) = &mut self.h265_vram {
                    *_pixelbuffer = false;
                    return Decoder::handle_vram_video_frame(decoder, h265s, _texture);
                }
                #[cfg(feature = "hwcodec")]
                if let Some(decoder) = &mut self.h265_ram {
                    return Decoder::handle_hwram_video_frame(decoder, h265s, rgb, &mut self.i420);
                }
                Err(anyhow!("don't support h265!"))
            }
            #[cfg(feature = "mediacodec")]
            video_frame::Union::H264s(h264s) => {
                *chroma = Some(Chroma::I420);
                if let Some(decoder) = &mut self.h264_media_codec {
                    Decoder::handle_mediacodec_video_frame(decoder, h264s, rgb)
                } else {
                    Err(anyhow!("don't support h264!"))
                }
            }
            #[cfg(feature = "mediacodec")]
            video_frame::Union::H265s(h265s) => {
                *chroma = Some(Chroma::I420);
                if let Some(decoder) = &mut self.h265_media_codec {
                    Decoder::handle_mediacodec_video_frame(decoder, h265s, rgb)
                } else {
                    Err(anyhow!("don't support h265!"))
                }
            }
            _ => Err(anyhow!("unsupported video frame type!")),
        }
    }

    // rgb [in/out] fmt and stride must be set in ImageRgb
    fn handle_vpxs_video_frame(
        decoder: &mut VpxDecoder,
        vpxs: &EncodedVideoFrames,
        rgb: &mut ImageRgb,
        chroma: &mut Option<Chroma>,
    ) -> ResultType<bool> {
        let mut ret = false;
        for vpx in vpxs.frames.iter() {
            for frame in decoder.decode(&vpx.data)? {
                *chroma = Some(frame.chroma());
                frame.to(rgb);
                ret = true;
            }
        }
        for frame in decoder.flush()? {
            *chroma = Some(frame.chroma());
            frame.to(rgb);
            ret = true;
        }
        Ok(ret)
    }

    // rgb [in/out] fmt and stride must be set in ImageRgb
    fn handle_av1s_video_frame(
        decoder: &mut AomDecoder,
        av1s: &EncodedVideoFrames,
        rgb: &mut ImageRgb,
        chroma: &mut Option<Chroma>,
    ) -> ResultType<bool> {
        let mut ret = false;
        for av1 in av1s.frames.iter() {
            for frame in decoder.decode(&av1.data)? {
                *chroma = Some(frame.chroma());
                frame.to(rgb);
                ret = true;
            }
        }
        for frame in decoder.flush()? {
            *chroma = Some(frame.chroma());
            frame.to(rgb);
            ret = true;
        }
        Ok(ret)
    }

    // rgb [in/out] fmt and stride must be set in ImageRgb
    #[cfg(feature = "hwcodec")]
    fn handle_hwram_video_frame(
        decoder: &mut HwRamDecoder,
        frames: &EncodedVideoFrames,
        rgb: &mut ImageRgb,
        i420: &mut Vec<u8>,
    ) -> ResultType<bool> {
        let mut ret = false;
        for h264 in frames.frames.iter() {
            for image in decoder.decode(&h264.data)? {
                // TODO: just process the last frame
                if image.to_fmt(rgb, i420).is_ok() {
                    ret = true;
                }
            }
        }
        return Ok(ret);
    }

    #[cfg(feature = "vram")]
    fn handle_vram_video_frame(
        decoder: &mut VRamDecoder,
        frames: &EncodedVideoFrames,
        texture: &mut ImageTexture,
    ) -> ResultType<bool> {
        let mut ret = false;
        for h26x in frames.frames.iter() {
            for image in decoder.decode(&h26x.data)? {
                *texture = ImageTexture {
                    texture: image.frame.texture,
                    w: image.frame.width as _,
                    h: image.frame.height as _,
                };
                ret = true;
            }
        }
        return Ok(ret);
    }

    // rgb [in/out] fmt and stride must be set in ImageRgb
    #[cfg(feature = "mediacodec")]
    fn handle_mediacodec_video_frame(
        decoder: &mut MediaCodecDecoder,
        frames: &EncodedVideoFrames,
        rgb: &mut ImageRgb,
    ) -> ResultType<bool> {
        let mut ret = false;
        for h264 in frames.frames.iter() {
            return decoder.decode(&h264.data, rgb);
        }
        return Ok(false);
    }

    fn preference(id: Option<&str>) -> (PreferCodec, Chroma) {
        let id = id.unwrap_or_default();
        if id.is_empty() {
            return (PreferCodec::Auto, Chroma::I420);
        }
        let options = PeerConfig::load(id).options;
        let codec = options
            .get("codec-preference")
            .map_or("".to_owned(), |c| c.to_owned());
        let codec = if codec == "vp8" {
            PreferCodec::VP8
        } else if codec == "vp9" {
            PreferCodec::VP9
        } else if codec == "av1" {
            PreferCodec::AV1
        } else if codec == "h264" {
            PreferCodec::H264
        } else if codec == "h265" {
            PreferCodec::H265
        } else {
            PreferCodec::Auto
        };
        let chroma = if options.get("i444") == Some(&"Y".to_string()) {
            Chroma::I444
        } else {
            Chroma::I420
        };
        (codec, chroma)
    }
}

#[cfg(any(feature = "hwcodec", feature = "mediacodec"))]
pub fn enable_hwcodec_option() -> bool {
    use camellia_remote_protocol::config::keys::OPTION_ENABLE_HWCODEC;

    if !cfg!(target_os = "ios") {
        return option2bool(
            OPTION_ENABLE_HWCODEC,
            &Config::get_option(OPTION_ENABLE_HWCODEC),
        );
    }
    false
}
#[cfg(feature = "vram")]
pub fn enable_vram_option(encode: bool) -> bool {
    use camellia_remote_protocol::config::keys::OPTION_ENABLE_HWCODEC;

    if cfg!(windows) {
        let enable = option2bool(
            OPTION_ENABLE_HWCODEC,
            &Config::get_option(OPTION_ENABLE_HWCODEC),
        );
        if encode {
            enable && enable_directx_capture()
        } else {
            enable && allow_d3d_render()
        }
    } else {
        false
    }
}

#[cfg(windows)]
pub fn enable_directx_capture() -> bool {
    use camellia_remote_protocol::config::keys::OPTION_ENABLE_DIRECTX_CAPTURE as OPTION;
    option2bool(OPTION, &Config::get_option(OPTION))
}

#[cfg(windows)]
pub fn allow_d3d_render() -> bool {
    use camellia_remote_protocol::config::keys::OPTION_ALLOW_D3D_RENDER as OPTION;
    option2bool(
        OPTION,
        &camellia_remote_protocol::config::LocalConfig::get_option(OPTION),
    )
}

/// Quality ratios applied on top of [`base_bitrate`].
///
/// The baseline is a modern desktop: a high-DPI display showing mostly static
/// text and UI, driven over a link that comfortably carries several Mbit/s.
/// Screen content is far less forgiving than camera video at low bitrates -
/// sharp glyph edges are exactly what a transform codec spends bits on - so
/// the ratios are set from what keeps text crisp, not from what keeps a video
/// watchable.
///
/// * `BR_BEST` targets visually lossless text at native resolution.
/// * `BR_BALANCED` is the default: crisp text, occasional softening while a
///   large region redraws.
/// * `BR_SPEED` favours latency and reach, accepting soft text during motion.
pub const BR_BEST: f32 = 2.2;
pub const BR_BALANCED: f32 = 1.0;
pub const BR_SPEED: f32 = 0.6;

/// Frame rate the resolution presets in [`base_bitrate`] are calibrated for.
pub const REFERENCE_FPS: u32 = 30;

/// Scales a bitrate calibrated at [`REFERENCE_FPS`] to the frame rate actually
/// in use.
///
/// Bits per frame - not bits per second - decide how much detail survives
/// encoding, so a target computed only from resolution silently starves every
/// frame as soon as the session speeds up: at 120 fps each frame would receive
/// a quarter of the bits it got at 30 fps. Doubling the frame rate does not,
/// however, need double the bandwidth, because consecutive frames are more
/// alike the closer together they are sampled and inter prediction turns that
/// similarity into savings. The square-root curve follows that observation and
/// is clamped so the two extremes stay sane: very low frame rates keep enough
/// bitrate to stay sharp, and very high ones do not run away with bandwidth.
pub fn fps_bitrate_scale(fps: u32) -> f32 {
    let fps = fps.clamp(1, 240) as f32;
    (fps / REFERENCE_FPS as f32).sqrt().clamp(0.6, 2.0)
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Quality {
    Best,
    Balanced,
    Low,
    Custom(f32),
}

impl Default for Quality {
    fn default() -> Self {
        Self::Balanced
    }
}

impl Quality {
    pub fn is_custom(&self) -> bool {
        match self {
            Quality::Custom(_) => true,
            _ => false,
        }
    }

    pub fn ratio(&self) -> f32 {
        match self {
            Quality::Best => BR_BEST,
            Quality::Balanced => BR_BALANCED,
            Quality::Low => BR_SPEED,
            Quality::Custom(v) => *v,
        }
    }
}

/// Reference bitrate in kbps for a resolution at [`REFERENCE_FPS`], ratio 1.0.
///
/// Calibrated for desktop screen content, where legible text is the binding
/// constraint. The curve is deliberately sublinear in pixel count: quadrupling
/// the pixels does not quadruple the entropy of a screen that is mostly flat
/// background, so the per-pixel allowance tapers as resolution grows.
pub fn base_bitrate(width: u32, height: u32) -> u32 {
    const RESOLUTION_PRESETS: &[(u32, u32, u32)] = &[
        (640, 480, 600),     // VGA, 307k pixels
        (800, 600, 800),     // SVGA, 480k pixels
        (1024, 768, 1100),   // XGA, 786k pixels
        (1280, 720, 1400),   // 720p, 921k pixels
        (1366, 768, 1500),   // HD, 1049k pixels
        (1440, 900, 1800),   // WXGA+, 1296k pixels
        (1600, 900, 2000),   // HD+, 1440k pixels
        (1920, 1080, 2800),  // 1080p, 2073k pixels
        (2048, 1080, 3000),  // 2K DCI, 2211k pixels
        (2560, 1440, 4200),  // 2K QHD, 3686k pixels
        (3440, 1440, 5200),  // UWQHD, 4953k pixels
        (3840, 2160, 7000),  // 4K UHD, 8294k pixels
        (7680, 4320, 16000), // 8K UHD, 33177k pixels
    ];
    let pixels = width * height;

    let (preset_pixels, preset_bitrate) = RESOLUTION_PRESETS
        .iter()
        .map(|(w, h, bitrate)| (w * h, bitrate))
        .min_by_key(|(preset_pixels, _)| {
            if *preset_pixels >= pixels {
                preset_pixels - pixels
            } else {
                pixels - preset_pixels
            }
        })
        .unwrap_or(((1920 * 1080) as u32, &2073)); // default 1080p

    let bitrate = (*preset_bitrate as f32 * (pixels as f32 / preset_pixels as f32)).round() as u32;

    #[cfg(target_os = "android")]
    {
        let fix = crate::Display::fix_quality() as u32;
        log::debug!("Android screen, fix quality:{}", fix);
        bitrate * fix
    }
    #[cfg(not(target_os = "android"))]
    {
        bitrate
    }
}

/// Encoder workers are row/tile scoped; this is a generous upper bound.
const MB_PER_CODEC_THREAD: u64 = 384;

/// Chooses a codec worker count from what the machine actually has spare.
///
/// Two conservative caps used to compound: the count was halved against the
/// core count *and* clamped to one thread per 2 GB of free memory, so a
/// six-core desktop with a few gigabytes free encoded on two threads. Codec
/// workers are row- or tile-scoped and cost far less than a gigabyte each, so
/// memory now only guards genuinely constrained machines and the budget
/// follows idle cores instead - keeping one free for capture, transport and
/// the rest of the app.
///
/// The result is rounded down to a power of two because tile-column
/// parallelism in VP9 and AV1 is defined in those terms; an odd count would
/// leave workers idle anyway.
fn thread_budget(cpus: usize, idle_cpus: f64, available_mb: u64, limit: usize) -> usize {
    let cpus = cpus.max(1);
    let mut res = idle_cpus.round().max(1.0) as usize;
    // Keep a core free so capture and the network loop are never starved.
    res = res.min(cpus.saturating_sub(1).max(1));
    res = res.min((available_mb / MB_PER_CODEC_THREAD).max(1) as usize);
    res = match res {
        _ if res >= 64 => 64,
        _ if res >= 32 => 32,
        _ if res >= 16 => 16,
        _ if res >= 8 => 8,
        _ if res >= 4 => 4,
        _ if res >= 2 => 2,
        _ => 1,
    };
    res.min(limit.max(1))
}

pub fn codec_thread_num(limit: usize) -> usize {
    let max: usize = num_cpus::get();
    let info;
    let idle_cpus;
    let mut s = System::new();
    s.refresh_memory();
    let available_mb = s.available_memory() / 1024 / 1024;
    let memory = available_mb / 1024;
    #[cfg(windows)]
    {
        let percent = camellia_remote_protocol::platform::windows::cpu_uage_one_minute();
        info = format!("cpu usage: {:?}", percent);
        // Treat reported usage as the share of the machine already committed.
        let idle_fraction = percent.map_or(1.0, |p| ((100.0 - p) / 100.0).clamp(0.0, 1.0));
        idle_cpus = max as f64 * idle_fraction;
    }
    #[cfg(not(windows))]
    {
        s.refresh_cpu_usage();
        // https://man7.org/linux/man-pages/man3/getloadavg.3.html
        let avg = s.load_average();
        info = format!("cpu loadavg: {}", avg.one);
        idle_cpus = max as f64 - avg.one;
    }
    let res = thread_budget(max, idle_cpus, available_mb, limit);
    // avoid frequent log
    let log = match THREAD_LOG_TIME.lock().unwrap().clone() {
        Some(instant) => instant.elapsed().as_secs() > 1,
        None => true,
    };
    if log {
        log::info!("cpu num: {max}, {info}, available memory: {memory}G, codec thread: {res}");
        *THREAD_LOG_TIME.lock().unwrap() = Some(Instant::now());
    }
    res
}

fn disable_av1() -> bool {
    // disable it for all 32 bit platforms
    std::mem::size_of::<usize>() == 4
}

#[cfg(not(target_os = "ios"))]
pub fn test_av1() {
    use camellia_remote_protocol::config::keys::OPTION_AV1_TEST;
    use camellia_remote_protocol::rand::RngExt;
    use std::{sync::Once, time::Duration};

    if disable_av1() || !Config::get_option(OPTION_AV1_TEST).is_empty() {
        log::info!("skip test av1");
        return;
    }

    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let f = || {
            let (width, height, quality, keyframe_interval, i444) = (1920, 1080, 1.0, None, false);
            let frame_count = 10;
            let block_size = 300;
            let move_step = 50;
            let generate_fake_data =
                |frame_index: u32, dst_fmt: EncodeYuvFormat| -> ResultType<Vec<u8>> {
                    let mut rng = camellia_remote_protocol::rand::rng();
                    let mut bgra = vec![0u8; (width * height * 4) as usize];
                    let gradient = frame_index as f32 / frame_count as f32;
                    // floating block
                    let x0 = (frame_index * move_step) % (width - block_size);
                    let y0 = (frame_index * move_step) % (height - block_size);
                    // Fill the block with random colors
                    for y in 0..block_size {
                        for x in 0..block_size {
                            let index = (((y0 + y) * width + x0 + x) * 4) as usize;
                            if index + 3 < bgra.len() {
                                let noise = rng.random_range(0..255) as f32 / 255.0;
                                let value = (255.0 * gradient + noise * 50.0) as u8;
                                bgra[index] = value;
                                bgra[index + 1] = value;
                                bgra[index + 2] = value;
                                bgra[index + 3] = 255;
                            }
                        }
                    }
                    let dst_stride_y = dst_fmt.stride[0];
                    let dst_stride_uv = dst_fmt.stride[1];
                    let mut dst = vec![0u8; (dst_fmt.h * dst_stride_y * 2) as usize];
                    let dst_y = dst.as_mut_ptr();
                    let dst_u = dst[dst_fmt.u..].as_mut_ptr();
                    let dst_v = dst[dst_fmt.v..].as_mut_ptr();
                    let res = unsafe {
                        crate::ARGBToI420(
                            bgra.as_ptr(),
                            (width * 4) as _,
                            dst_y,
                            dst_stride_y as _,
                            dst_u,
                            dst_stride_uv as _,
                            dst_v,
                            dst_stride_uv as _,
                            width as _,
                            height as _,
                        )
                    };
                    if res != 0 {
                        bail!("ARGBToI420 failed: {}", res);
                    }
                    Ok(dst)
                };
            let Ok(mut av1) = AomEncoder::new(
                EncoderCfg::AOM(AomEncoderConfig {
                    width,
                    height,
                    quality,
                    keyframe_interval,
                }),
                i444,
            ) else {
                return false;
            };
            let mut key_frame_time = Duration::ZERO;
            let mut non_key_frame_time_sum = Duration::ZERO;
            let pts = Instant::now();
            let yuvfmt = av1.yuvfmt();
            for i in 0..frame_count {
                let Ok(yuv) = generate_fake_data(i, yuvfmt.clone()) else {
                    return false;
                };
                let start = Instant::now();
                if av1
                    .encode(pts.elapsed().as_millis() as _, &yuv, super::STRIDE_ALIGN)
                    .is_err()
                {
                    log::debug!("av1 encode failed");
                    if i == 0 {
                        return false;
                    }
                }
                if i == 0 {
                    key_frame_time = start.elapsed();
                } else {
                    non_key_frame_time_sum += start.elapsed();
                }
            }
            let non_key_frame_time = non_key_frame_time_sum / (frame_count - 1);
            log::info!(
                "av1 time: key: {:?}, non-key: {:?}, consume: {:?}",
                key_frame_time,
                non_key_frame_time,
                pts.elapsed()
            );
            key_frame_time < Duration::from_millis(90)
                && non_key_frame_time < Duration::from_millis(30)
        };
        std::thread::spawn(move || {
            let v = f();
            Config::set_option(
                OPTION_AV1_TEST.to_string(),
                if v { "Y" } else { "N" }.to_string(),
            );
        });
    });
}

#[cfg(test)]
mod bitrate_tests {
    use super::*;

    /// What the previous policy would have produced, kept as the comparison
    /// point for the thread-budget tests below.
    fn legacy_thread_budget(cpus: usize, idle_cpus: f64, available_mb: u64) -> usize {
        let mut res = (idle_cpus * 0.5).round() as usize;
        res = res.min(cpus / 2);
        res = res.min((available_mb / 1024) as usize / 2);
        match res {
            _ if res >= 8 => 8,
            _ if res >= 4 => 4,
            _ if res >= 2 => 2,
            _ => 1,
        }
    }

    #[test]
    fn idle_machines_are_no_longer_starved_of_codec_threads() {
        // A six-core desktop, idle, with 8 GB free: the old policy halved the
        // core count and then halved the free memory, landing on two threads.
        let cpus = 6;
        let idle = 5.5;
        let free_mb = 8 * 1024;
        assert_eq!(legacy_thread_budget(cpus, idle, free_mb), 2);
        assert_eq!(thread_budget(cpus, idle, free_mb, 64), 4);

        // A sixteen-core workstation gains proportionally more.
        assert_eq!(legacy_thread_budget(16, 15.0, 16 * 1024), 8);
        assert_eq!(thread_budget(16, 15.0, 16 * 1024, 64), 8);
        assert_eq!(thread_budget(32, 31.0, 32 * 1024, 64), 16);
    }

    #[test]
    fn a_busy_machine_still_yields() {
        // Load consumes most of the cores, so the encoder takes what is left.
        assert!(thread_budget(8, 1.5, 8 * 1024, 64) <= 2);
        assert_eq!(thread_budget(8, 0.0, 8 * 1024, 64), 1);
        assert_eq!(thread_budget(8, -3.0, 8 * 1024, 64), 1);
    }

    #[test]
    fn memory_guards_only_constrained_machines() {
        // Plenty of cores but almost no memory: fall back to a single worker.
        assert_eq!(thread_budget(16, 15.0, 256, 64), 1);
        // A gigabyte free is no longer a reason to serialise a modern encode.
        assert!(thread_budget(16, 15.0, 4 * 1024, 64) >= 8);
    }

    #[test]
    fn the_caller_limit_is_respected() {
        assert_eq!(thread_budget(64, 63.0, 64 * 1024, 4), 4);
        assert_eq!(thread_budget(64, 63.0, 64 * 1024, 0), 1);
    }

    #[test]
    fn a_single_core_machine_still_encodes() {
        assert_eq!(thread_budget(1, 1.0, 8 * 1024, 64), 1);
        assert_eq!(thread_budget(0, 0.0, 0, 64), 1);
    }

    #[test]
    fn quality_presets_are_ordered_and_positive() {
        assert!(BR_SPEED < BR_BALANCED);
        assert!(BR_BALANCED < BR_BEST);
        assert!(BR_SPEED > 0.0);
        for quality in [Quality::Best, Quality::Balanced, Quality::Low] {
            assert!(quality.ratio() > 0.0);
        }
        assert_eq!(Quality::Custom(0.75).ratio(), 0.75);
    }

    #[test]
    fn base_bitrate_grows_with_resolution_but_not_linearly() {
        let hd = base_bitrate(1280, 720);
        let fhd = base_bitrate(1920, 1080);
        let uhd = base_bitrate(3840, 2160);
        assert!(hd < fhd && fhd < uhd);

        // Four times the pixels of 1080p must not cost four times the bitrate:
        // a larger desktop is mostly more flat background.
        assert!(uhd < fhd * 4);
        // ... but it must still be a clear step up.
        assert!(uhd > fhd * 2);
    }

    #[test]
    fn base_bitrate_keeps_text_legible_at_common_resolutions() {
        // Regression guard for the calibration: screen content needs a few
        // Mbit/s at 1080p before glyph edges start smearing.
        assert!(base_bitrate(1920, 1080) >= 2500);
        assert!(base_bitrate(2560, 1440) >= 3800);
        assert!(base_bitrate(3840, 2160) >= 6000);
    }

    #[test]
    fn fps_scale_tracks_frame_rate_sublinearly() {
        assert_eq!(fps_bitrate_scale(REFERENCE_FPS), 1.0);

        let f60 = fps_bitrate_scale(60);
        let f120 = fps_bitrate_scale(120);
        // Faster sessions get more bandwidth ...
        assert!(f60 > 1.0 && f120 > f60);
        // ... but less than proportionally: neighbouring frames are similar,
        // so inter prediction absorbs part of the increase.
        assert!(f60 < 2.0 && f120 < 4.0);
    }

    #[test]
    fn fps_scale_is_bounded_at_both_extremes() {
        // A crawling session must not collapse to an unreadable bitrate.
        assert_eq!(fps_bitrate_scale(1), 0.6);
        assert_eq!(fps_bitrate_scale(0), 0.6);
        // A very fast one must not run away with bandwidth.
        assert_eq!(fps_bitrate_scale(240), 2.0);
        assert_eq!(fps_bitrate_scale(u32::MAX), 2.0);
    }

    #[test]
    fn per_frame_budget_no_longer_collapses_at_high_fps() {
        // The defect this model fixes: with a frame-rate-independent target,
        // bits per frame fell as 1/fps. Now a 4x faster session keeps a usable
        // share of the per-frame budget instead of a quarter of it.
        let bitrate_at = |fps: u32| base_bitrate(1920, 1080) as f32 * fps_bitrate_scale(fps);
        let per_frame = |fps: u32| bitrate_at(fps) / fps as f32;

        let ratio = per_frame(120) / per_frame(30);
        assert!(ratio > 0.45, "per-frame budget fell too far: {}", ratio);
        assert!(
            ratio < 1.0,
            "high fps should still cost some detail: {}",
            ratio
        );
    }
}
