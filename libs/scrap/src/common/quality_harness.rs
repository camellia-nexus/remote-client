//! Encode/decode measurement harness for the Camellia bitrate model.
//!
//! This is a real measurement rig, not a simulation: every number it prints
//! comes from running libvpx over synthetic screen content and comparing the
//! decoded pixels against the source pixels.
//!
//! # Running it
//!
//! Default (fast smoke subset, runs with the rest of the crate's tests):
//!
//! ```text
//! cargo test -p scrap --features linux-pkg-config quality_harness
//! ```
//!
//! Full comparison matrix (resolution x fps x quality, legacy vs current
//! bitrate model). It is `#[ignore]`d because it takes minutes, and it must be
//! run in `--release` or the harness' own PSNR/SSIM loops dominate the runtime:
//!
//! ```text
//! cargo test -p scrap --features linux-pkg-config --release -- --ignored --nocapture bitrate_model_matrix
//! ```
//!
//! `--features linux-pkg-config` is required on hosts without `VCPKG_ROOT`;
//! `build.rs` otherwise fails looking for a vcpkg tree.
//!
//! # How a bitrate model is fed to the encoder
//!
//! [`VpxEncoder`] takes a single knob, `VpxEncoderConfig::quality`, and derives
//! both `rc_target_bitrate` (`base_bitrate(w, h) * quality`) and the quantizer
//! bounds from it. To drive the encoder at an arbitrary target the harness
//! inverts that relation: `quality = target_kbps / base_bitrate(w, h)`. The
//! encoder therefore ends up at exactly the kbps the model under test asks for,
//! with the quantizer window that production would pick for that bitrate. The
//! achieved target is read back from the encoder and asserted, so the mapping
//! cannot silently drift.
//!
//! # What is measured
//!
//! Per configuration, over `MEASURED` frames after `WARMUP` frames (the warmup
//! covers the keyframe and lets CBR rate control settle):
//!
//! * encode wall time per frame, mean and p95
//! * decode wall time per frame, mean
//! * achieved bitrate from real encoded byte counts
//! * PSNR and SSIM of the Y plane, source vs decoded
//!
//! Frames that libvpx drops (`rc_dropframe_thresh` is 25 in production config)
//! contribute zero bytes and are scored against the last frame the decoder
//! actually produced - which is what a viewer would be looking at. Starving the
//! encoder is therefore penalised in the quality columns rather than hidden.

use std::{
    env,
    fs::OpenOptions,
    io::{BufWriter, Write},
    path::PathBuf,
    time::{Duration, Instant},
};

use camellia_remote_protocol::{
    serde_json::{json, to_writer},
    sysinfo::System,
};

use crate::codec::{
    base_bitrate, codec_thread_num, fps_bitrate_scale, EncoderApi, EncoderCfg, Quality,
};
use crate::vpxcodec::{
    VpxDecoder, VpxDecoderConfig, VpxEncoder, VpxEncoderConfig, VpxVideoCodecId,
};
use crate::{EncodeYuvFormat, GoogleImage, STRIDE_ALIGN};

// ---------------------------------------------------------------------------
// Bitrate models under comparison
// ---------------------------------------------------------------------------

/// Resolution presets of the pre-Camellia `base_bitrate`, kept verbatim so the
/// legacy arm of the comparison is the real thing and not a rounded stand-in.
const LEGACY_PRESETS: &[(u32, u32, u32)] = &[
    (640, 480, 400),
    (800, 600, 500),
    (1024, 768, 800),
    (1280, 720, 1000),
    (1366, 768, 1100),
    (1440, 900, 1300),
    (1600, 900, 1500),
    (1920, 1080, 2073),
    (2048, 1080, 2200),
    (2560, 1440, 3000),
    (3440, 1440, 4000),
    (3840, 2160, 5000),
    (7680, 4320, 12000),
];

/// Legacy quality ratios (`BR_SPEED` / `BR_BALANCED` / `BR_BEST` before the
/// recalibration).
fn legacy_ratio(quality: Quality) -> f32 {
    match quality {
        Quality::Low => 0.5,
        Quality::Balanced => 0.67,
        Quality::Best => 1.5,
        Quality::Custom(v) => v,
    }
}

/// Legacy `base_bitrate`: nearest preset by pixel count, scaled linearly.
fn legacy_base_bitrate(width: u32, height: u32) -> u32 {
    let pixels = width * height;
    let (preset_pixels, preset_bitrate) = LEGACY_PRESETS
        .iter()
        .map(|(w, h, bitrate)| (w * h, *bitrate))
        .min_by_key(|(preset_pixels, _)| preset_pixels.abs_diff(pixels))
        .unwrap_or((1920 * 1080, 2073));
    (preset_bitrate as f32 * (pixels as f32 / preset_pixels as f32)).round() as u32
}

/// Target the legacy model hands to the encoder. Frame rate is not an input -
/// that is the defect under test.
fn legacy_kbps(width: u32, height: u32, quality: Quality) -> u32 {
    (legacy_base_bitrate(width, height) as f32 * legacy_ratio(quality)) as u32
}

/// Target the current model hands to the encoder, matching what
/// `VideoQoS::ratio()` multiplies into the encoder ratio today.
fn current_kbps(width: u32, height: u32, fps: u32, quality: Quality) -> u32 {
    (base_bitrate(width, height) as f32 * quality.ratio() * fps_bitrate_scale(fps)) as u32
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Model {
    Legacy,
    Current,
}

impl Model {
    fn label(self) -> &'static str {
        match self {
            Model::Legacy => "legacy",
            Model::Current => "current",
        }
    }

    fn kbps(self, width: u32, height: u32, fps: u32, quality: Quality) -> u32 {
        match self {
            Model::Legacy => legacy_kbps(width, height, quality),
            Model::Current => current_kbps(width, height, fps, quality),
        }
    }
}

fn quality_label(quality: Quality) -> &'static str {
    match quality {
        Quality::Low => "Low",
        Quality::Balanced => "Balanced",
        Quality::Best => "Best",
        Quality::Custom(_) => "Custom",
    }
}

// ---------------------------------------------------------------------------
// Synthetic screen content
// ---------------------------------------------------------------------------

/// How much of the screen changes between frames.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Motion {
    /// Reading a document: only the caret blinks.
    Static,
    /// Typical interactive use: pointer moves, a terminal prints a line every
    /// few frames, caret blinks.
    Light,
    /// Smooth-scrolling a text document while the pointer sweeps across it -
    /// the case where per-frame bit budget decides whether glyphs survive.
    Heavy,
}

impl Motion {
    fn label(self) -> &'static str {
        match self {
            Motion::Static => "static",
            Motion::Light => "light",
            Motion::Heavy => "heavy",
        }
    }

    /// Vertical scroll of the editor text area, in pixels per frame.
    fn scroll_px_per_frame(self) -> usize {
        match self {
            Motion::Static | Motion::Light => 0,
            Motion::Heavy => 3,
        }
    }

    /// Frames between two terminal output lines. `0` means the terminal is idle.
    fn terminal_period(self) -> usize {
        match self {
            Motion::Static => 0,
            Motion::Light => 6,
            Motion::Heavy => 2,
        }
    }

    /// Pointer speed along its path, radians per frame.
    fn pointer_speed(self) -> f64 {
        match self {
            Motion::Static => 0.0,
            Motion::Light => 0.05,
            Motion::Heavy => 0.17,
        }
    }
}

/// Glyph cell geometry. Deliberately fixed in pixels rather than scaled with
/// the resolution: a bigger desktop shows more text at the same size, which is
/// exactly why higher resolutions carry more entropy.
const GLYPH_W: usize = 5;
const GLYPH_H: usize = 9;
const CELL_W: usize = 7;
const CELL_H: usize = 13;

// Luma levels of the mock desktop.
const L_DESKTOP: u8 = 44;
const L_TASKBAR: u8 = 26;
const L_TASKBAR_ICON: u8 = 120;
const L_WINDOW_EDGE: u8 = 205;
const L_TITLEBAR: u8 = 68;
const L_TITLE_TEXT: u8 = 208;
const L_SIDEBAR: u8 = 40;
const L_SIDEBAR_TEXT: u8 = 168;
const L_GUTTER: u8 = 226;
const L_GUTTER_TEXT: u8 = 122;
const L_PAGE: u8 = 246;
const L_PAGE_TEXT: u8 = 20;
const L_TERM_BG: u8 = 14;
const L_TERM_TEXT: u8 = 198;
const L_CURSOR_FILL: u8 = 236;
const L_CURSOR_EDGE: u8 = 16;

#[derive(Clone, Copy)]
struct Rect {
    x: usize,
    y: usize,
    w: usize,
    h: usize,
}

/// Mutable view of one image plane.
struct Plane<'a> {
    data: &'a mut [u8],
    stride: usize,
    w: usize,
    h: usize,
}

impl<'a> Plane<'a> {
    fn fill_rect(&mut self, x: usize, y: usize, w: usize, h: usize, v: u8) {
        if x >= self.w || y >= self.h {
            return;
        }
        let w = w.min(self.w - x);
        let h = h.min(self.h - y);
        for r in y..y + h {
            let start = r * self.stride + x;
            self.data[start..start + w].fill(v);
        }
    }

    fn outline(&mut self, r: Rect, thickness: usize, v: u8) {
        self.fill_rect(r.x, r.y, r.w, thickness, v);
        self.fill_rect(r.x, r.y + r.h.saturating_sub(thickness), r.w, thickness, v);
        self.fill_rect(r.x, r.y, thickness, r.h, v);
        self.fill_rect(r.x + r.w.saturating_sub(thickness), r.y, thickness, r.h, v);
    }

    fn set(&mut self, x: usize, y: usize, v: u8) {
        if x < self.w && y < self.h {
            self.data[y * self.stride + x] = v;
        }
    }
}

/// Cheap deterministic bit mixer (no `rand` dependency, identical every run).
fn hash32(mut x: u32) -> u32 {
    x ^= x >> 16;
    x = x.wrapping_mul(0x7feb_352d);
    x ^= x >> 15;
    x = x.wrapping_mul(0x846c_a68b);
    x ^= x >> 16;
    x
}

/// A 64-entry procedural "font": stems, bars and diagonals combined from the
/// glyph index. The point is not legibility but the statistics of text - small,
/// sharp, high-contrast marks on a flat page, which is what a transform codec
/// finds expensive and what a bitrate model has to pay for.
fn build_font() -> Vec<[u8; GLYPH_H]> {
    let mut font = Vec::with_capacity(64);
    for g in 0..64u32 {
        let mut rows = [0u8; GLYPH_H];
        let full = (1u8 << GLYPH_W) - 1;
        if g & 1 != 0 {
            for row in rows.iter_mut() {
                *row |= 1;
            }
        }
        if g & 2 != 0 {
            for row in rows.iter_mut() {
                *row |= 1 << (GLYPH_W - 1);
            }
        }
        if g & 4 != 0 {
            rows[0] = full;
        }
        if g & 8 != 0 {
            rows[GLYPH_H / 2] = full;
        }
        if g & 16 != 0 {
            rows[GLYPH_H - 1] = full;
        }
        if g & 32 != 0 {
            for (r, row) in rows.iter_mut().enumerate() {
                *row |= 1 << (r * (GLYPH_W - 1) / (GLYPH_H - 1));
            }
        }
        font.push(rows);
    }
    font
}

/// A mock desktop: wallpaper, taskbar, an editor window (sidebar, line-number
/// gutter, text page) and a terminal window, plus a pointer and a caret.
struct Scene {
    w: usize,
    h: usize,
    stride_y: usize,
    y_plane_len: usize,
    buf_len: usize,
    motion: Motion,
    font: Vec<[u8; GLYPH_H]>,
    page: Rect,
    term: Rect,
    base: Vec<u8>,
}

impl Scene {
    fn new(width: usize, height: usize, fmt: &EncodeYuvFormat, motion: Motion) -> Self {
        let stride_y = fmt.stride[0];
        let stride_uv = fmt.stride[1];
        let y_plane_len = fmt.h * stride_y;
        let buf_len = fmt.v + (fmt.h / 2) * stride_uv;

        // Window geometry, proportional so every resolution looks like the
        // same desktop seen at a different size.
        let ex = width / 24;
        let ey = height / 16;
        let ew = width * 7 / 12;
        let eh = height * 13 / 16;
        let title_h = 30;
        let sidebar_w = ew / 5;
        let gutter_w = 42;
        let page = Rect {
            x: ex + sidebar_w + gutter_w,
            y: ey + title_h,
            w: ew.saturating_sub(sidebar_w + gutter_w),
            h: eh.saturating_sub(title_h),
        };
        let tx = ex + ew + width / 40;
        let term_outer = Rect {
            x: tx,
            y: height / 5,
            w: width.saturating_sub(tx + width / 24),
            h: height / 2,
        };
        let term = Rect {
            x: term_outer.x + 6,
            y: term_outer.y + title_h + 4,
            w: term_outer.w.saturating_sub(12),
            h: term_outer.h.saturating_sub(title_h + 10),
        };

        let mut scene = Scene {
            w: width,
            h: height,
            stride_y,
            y_plane_len,
            buf_len,
            motion,
            font: build_font(),
            page,
            term,
            base: Vec::new(),
        };

        let mut base = vec![0u8; buf_len];
        scene.paint_static(
            &mut base,
            fmt,
            Rect {
                x: ex,
                y: ey,
                w: ew,
                h: eh,
            },
            term_outer,
            title_h,
            sidebar_w,
            gutter_w,
        );
        scene.base = base;
        scene
    }

    fn plane<'b>(&self, buf: &'b mut [u8]) -> Plane<'b> {
        Plane {
            data: &mut buf[..self.y_plane_len],
            stride: self.stride_y,
            w: self.w,
            h: self.h,
        }
    }

    fn draw_glyph(&self, p: &mut Plane, x: usize, y: isize, glyph: usize, fg: u8) {
        let rows = &self.font[glyph & 63];
        for (r, mask) in rows.iter().enumerate() {
            let yy = y + r as isize;
            if yy < 0 {
                continue;
            }
            let yy = yy as usize;
            for c in 0..GLYPH_W {
                if mask & (1 << c) != 0 {
                    p.set(x + c, yy, fg);
                }
            }
        }
    }

    /// One line of pseudo-text: word-like runs of glyphs separated by spaces.
    fn draw_text_line(
        &self,
        p: &mut Plane,
        x0: usize,
        y: isize,
        max_cols: usize,
        seed: u32,
        fg: u8,
    ) {
        if y + GLYPH_H as isize <= 0 || y >= self.h as isize {
            return;
        }
        // Lines are ragged, like real text.
        let cols = (max_cols * (55 + (hash32(seed) % 45) as usize)) / 100;
        let mut col = 0usize;
        let mut word_left = 0usize;
        while col < cols {
            if word_left == 0 {
                word_left =
                    2 + (hash32(seed ^ (col as u32).wrapping_mul(0x9e37_79b9)) % 8) as usize;
                if col > 0 {
                    col += 1;
                    if col >= cols {
                        break;
                    }
                }
            }
            let g = (hash32(seed.wrapping_add((col as u32).wrapping_mul(0x85eb_ca6b))) % 63) + 1;
            self.draw_glyph(p, x0 + col * CELL_W, y, g as usize, fg);
            col += 1;
            word_left -= 1;
        }
    }

    /// Editor text page, scrolled by `scroll_px` pixels. Redrawn every frame in
    /// [`Motion::Heavy`], painted once into the base frame otherwise.
    fn paint_page(&self, p: &mut Plane, scroll_px: usize) {
        if self.page.w == 0 || self.page.h == 0 {
            return;
        }
        p.fill_rect(self.page.x, self.page.y, self.page.w, self.page.h, L_PAGE);
        let first_line = scroll_px / CELL_H;
        let sub = (scroll_px % CELL_H) as isize;
        let visible = self.page.h / CELL_H + 2;
        let cols = self.page.w.saturating_sub(12) / CELL_W;
        for i in 0..visible {
            let doc_line = first_line + i;
            let y = self.page.y as isize + (i * CELL_H) as isize - sub + 2;
            if y as usize + GLYPH_H >= self.page.y + self.page.h {
                break;
            }
            // Indent like source code, and leave the occasional blank line.
            if doc_line % 11 == 7 {
                continue;
            }
            let indent = (hash32(doc_line as u32 ^ 0x5bf0_3635) % 4) as usize * 2;
            self.draw_text_line(
                p,
                self.page.x + 8 + indent * CELL_W,
                y,
                cols.saturating_sub(indent),
                0x1000_0000 ^ doc_line as u32,
                L_PAGE_TEXT,
            );
        }
    }

    /// Terminal scrollback, `first_line` advancing as output is appended.
    fn paint_terminal(&self, p: &mut Plane, first_line: usize) {
        if self.term.w == 0 || self.term.h == 0 {
            return;
        }
        p.fill_rect(
            self.term.x,
            self.term.y,
            self.term.w,
            self.term.h,
            L_TERM_BG,
        );
        let rows = self.term.h / CELL_H;
        let cols = self.term.w.saturating_sub(8) / CELL_W;
        for i in 0..rows {
            let line = first_line + i;
            let y = (self.term.y + i * CELL_H + 2) as isize;
            self.draw_text_line(
                p,
                self.term.x + 4,
                y,
                cols,
                0x2000_0000 ^ line as u32,
                L_TERM_TEXT,
            );
        }
    }

    /// Everything that never changes, plus a first pass of the dynamic regions
    /// so a static frame is already complete.
    #[allow(clippy::too_many_arguments)]
    fn paint_static(
        &self,
        buf: &mut [u8],
        fmt: &EncodeYuvFormat,
        editor: Rect,
        term_outer: Rect,
        title_h: usize,
        sidebar_w: usize,
        gutter_w: usize,
    ) {
        {
            let mut p = self.plane(buf);

            // Wallpaper: a very low frequency vertical ramp, cheap to encode.
            for r in 0..self.h {
                let v = L_DESKTOP + (r * 18 / self.h.max(1)) as u8;
                let start = r * self.stride_y;
                p.data[start..start + self.w].fill(v);
            }

            // Taskbar with icons.
            let tb_h = self.h / 18;
            let tb_y = self.h - tb_h;
            p.fill_rect(0, tb_y, self.w, tb_h, L_TASKBAR);
            let icon = tb_h * 3 / 5;
            for i in 0..9 {
                p.fill_rect(
                    12 + i * (icon + 10),
                    tb_y + (tb_h - icon) / 2,
                    icon,
                    icon,
                    L_TASKBAR_ICON.wrapping_add((i as u8) * 7),
                );
            }

            // Editor window.
            p.fill_rect(editor.x, editor.y, editor.w, title_h, L_TITLEBAR);
            self.draw_text_line(
                &mut p,
                editor.x + 12,
                (editor.y + 10) as isize,
                24,
                0x3000_0001,
                L_TITLE_TEXT,
            );
            for i in 0..3 {
                p.fill_rect(
                    editor.x + editor.w - 20 - i * 18,
                    editor.y + 11,
                    9,
                    9,
                    L_WINDOW_EDGE,
                );
            }
            p.fill_rect(
                editor.x,
                editor.y + title_h,
                sidebar_w,
                editor.h - title_h,
                L_SIDEBAR,
            );
            let sidebar_rows = (editor.h - title_h) / (CELL_H + 5);
            for i in 0..sidebar_rows {
                self.draw_text_line(
                    &mut p,
                    editor.x + 10 + (i % 3) * CELL_W,
                    (editor.y + title_h + 8 + i * (CELL_H + 5)) as isize,
                    sidebar_w.saturating_sub(20) / CELL_W,
                    0x4000_0000 ^ i as u32,
                    L_SIDEBAR_TEXT,
                );
            }
            p.fill_rect(
                editor.x + sidebar_w,
                editor.y + title_h,
                gutter_w,
                editor.h - title_h,
                L_GUTTER,
            );
            p.outline(editor, 2, L_WINDOW_EDGE);

            // Terminal window.
            p.fill_rect(
                term_outer.x,
                term_outer.y,
                term_outer.w,
                term_outer.h,
                L_TERM_BG,
            );
            p.fill_rect(
                term_outer.x,
                term_outer.y,
                term_outer.w,
                title_h,
                L_TITLEBAR,
            );
            self.draw_text_line(
                &mut p,
                term_outer.x + 12,
                (term_outer.y + 10) as isize,
                18,
                0x3000_0002,
                L_TITLE_TEXT,
            );
            p.outline(term_outer, 2, L_WINDOW_EDGE);

            self.paint_page(&mut p, 0);
            self.paint_terminal(&mut p, 0);

            // Line numbers, drawn after the gutter so they sit on top.
            let gutter_rows = (editor.h - title_h) / CELL_H;
            for i in 0..gutter_rows {
                self.draw_text_line(
                    &mut p,
                    editor.x + sidebar_w + 8,
                    (editor.y + title_h + i * CELL_H + 2) as isize,
                    3,
                    0x5000_0000 ^ i as u32,
                    L_GUTTER_TEXT,
                );
            }
        }

        // Chroma: neutral everywhere, with a blue-ish wallpaper. Written once;
        // every animated region sits on neutral chroma, so per-frame updates
        // only need to touch luma.
        let uv_h = fmt.h / 2;
        let stride_uv = fmt.stride[1];
        buf[fmt.u..fmt.u + uv_h * stride_uv].fill(128);
        buf[fmt.v..fmt.v + uv_h * stride_uv].fill(128);
        for r in 0..uv_h {
            let u = fmt.u + r * stride_uv;
            let v = fmt.v + r * stride_uv;
            buf[u..u + self.w / 2].fill(152);
            buf[v..v + self.w / 2].fill(104);
        }
    }

    fn pointer_pos(&self, idx: usize) -> (usize, usize) {
        let t = idx as f64 * self.motion.pointer_speed();
        let cx = self.w as f64 * 0.45;
        let cy = self.h as f64 * 0.5;
        let ax = self.w as f64 * 0.28;
        let ay = self.h as f64 * 0.30;
        let x = cx + ax * (t).sin();
        let y = cy + ay * (t * 0.73).cos();
        (
            (x.max(0.0) as usize).min(self.w.saturating_sub(1)),
            (y.max(0.0) as usize).min(self.h.saturating_sub(1)),
        )
    }

    fn draw_pointer(&self, p: &mut Plane, x: usize, y: usize) {
        const CUR_H: usize = 18;
        const CUR_W: usize = 11;
        for r in 0..CUR_H {
            let width = (r + 1).min(CUR_W);
            for c in 0..width {
                let edge = c == 0 || c + 1 == width || r + 1 == CUR_H;
                p.set(
                    x + c,
                    y + r,
                    if edge { L_CURSOR_EDGE } else { L_CURSOR_FILL },
                );
            }
        }
    }

    /// Render frame `idx` into `out` (I420, encoder stride layout).
    fn frame(&self, idx: usize, out: &mut Vec<u8>) {
        if out.len() != self.buf_len {
            out.resize(self.buf_len, 0);
        }
        out.copy_from_slice(&self.base);
        let mut p = self.plane(out);

        let scroll = idx * self.motion.scroll_px_per_frame();
        if scroll > 0 {
            self.paint_page(&mut p, scroll);
        }
        let period = self.motion.terminal_period();
        if period > 0 {
            self.paint_terminal(&mut p, idx / period);
        }

        // Blinking caret on the terminal's last line, present in every mode.
        if (idx / 15) % 2 == 0 && self.term.h >= CELL_H {
            let rows = self.term.h / CELL_H;
            let cy = self.term.y + rows.saturating_sub(1) * CELL_H + 2;
            p.fill_rect(self.term.x + 4, cy, 2, GLYPH_H, L_TERM_TEXT);
        }

        let (px, py) = self.pointer_pos(idx);
        self.draw_pointer(&mut p, px, py);
    }
}

// ---------------------------------------------------------------------------
// Quality metrics
// ---------------------------------------------------------------------------

/// Peak signal-to-noise ratio of the Y plane, in dB. Identical planes report
/// 99.0 rather than infinity.
fn psnr_y(a: &[u8], a_stride: usize, b: &[u8], b_stride: usize, w: usize, h: usize) -> f64 {
    let mut sse = 0u64;
    for r in 0..h {
        let ra = &a[r * a_stride..r * a_stride + w];
        let rb = &b[r * b_stride..r * b_stride + w];
        for c in 0..w {
            let d = ra[c] as i32 - rb[c] as i32;
            sse += (d * d) as u64;
        }
    }
    if sse == 0 {
        return 99.0;
    }
    let mse = sse as f64 / (w * h) as f64;
    10.0 * (255.0 * 255.0 / mse).log10()
}

/// Mean SSIM of the Y plane over 8x8 windows stepped by 4 (the same sampling
/// libvpx's own `vpx_ssim2` uses), with the standard stabilising constants
/// C1 = (0.01 * 255)^2 and C2 = (0.03 * 255)^2 and biased (population)
/// variance/covariance.
fn ssim_y(a: &[u8], a_stride: usize, b: &[u8], b_stride: usize, w: usize, h: usize) -> f64 {
    const C1: f64 = 6.5025;
    const C2: f64 = 58.5225;
    const WIN: usize = 8;
    const STEP: usize = 4;
    if w < WIN || h < WIN {
        return 1.0;
    }
    let n = (WIN * WIN) as f64;
    let mut total = 0.0f64;
    let mut windows = 0usize;
    let mut y = 0usize;
    while y + WIN <= h {
        let mut x = 0usize;
        while x + WIN <= w {
            let (mut sa, mut sb, mut saa, mut sbb, mut sab) = (0u32, 0u32, 0u32, 0u32, 0u32);
            for r in 0..WIN {
                let ra = &a[(y + r) * a_stride + x..(y + r) * a_stride + x + WIN];
                let rb = &b[(y + r) * b_stride + x..(y + r) * b_stride + x + WIN];
                for c in 0..WIN {
                    let pa = ra[c] as u32;
                    let pb = rb[c] as u32;
                    sa += pa;
                    sb += pb;
                    saa += pa * pa;
                    sbb += pb * pb;
                    sab += pa * pb;
                }
            }
            let mu_a = sa as f64 / n;
            let mu_b = sb as f64 / n;
            let var_a = saa as f64 / n - mu_a * mu_a;
            let var_b = sbb as f64 / n - mu_b * mu_b;
            let cov = sab as f64 / n - mu_a * mu_b;
            let num = (2.0 * mu_a * mu_b + C1) * (2.0 * cov + C2);
            let den = (mu_a * mu_a + mu_b * mu_b + C1) * (var_a + var_b + C2);
            total += num / den;
            windows += 1;
            x += STEP;
        }
        y += STEP;
    }
    total / windows as f64
}

// ---------------------------------------------------------------------------
// Measurement
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug)]
struct Case {
    width: u32,
    height: u32,
    fps: u32,
    quality: Quality,
    motion: Motion,
    model: Model,
    warmup: usize,
    measured: usize,
}

#[derive(Clone, Copy, Debug)]
struct Measurement {
    target_kbps: u32,
    achieved_kbps: f64,
    kbit_per_frame: f64,
    psnr_db: f64,
    ssim: f64,
    encode_ms_mean: f64,
    encode_ms_p95: f64,
    decode_ms_mean: f64,
    dropped: usize,
}

fn mean(v: &[f64]) -> f64 {
    if v.is_empty() {
        0.0
    } else {
        v.iter().sum::<f64>() / v.len() as f64
    }
}

/// Nearest-rank p95.
fn p95(v: &[f64]) -> f64 {
    if v.is_empty() {
        return 0.0;
    }
    let mut s = v.to_vec();
    s.sort_by(f64::total_cmp);
    let idx = (((s.len() as f64) * 0.95).ceil() as usize).saturating_sub(1);
    s[idx.min(s.len() - 1)]
}

/// Encode and decode `warmup + measured` frames of synthetic desktop content at
/// the bitrate the given model prescribes, and report what came out.
fn run_case(case: Case) -> Measurement {
    let target_kbps = case
        .model
        .kbps(case.width, case.height, case.fps, case.quality);
    assert!(
        target_kbps > 0,
        "model produced a zero bitrate for {:?}",
        case
    );

    // Invert VpxEncoder's `rc_target_bitrate = base_bitrate(w, h) * quality`.
    // The +0.5 absorbs the `as u32` truncation inside the encoder.
    let base = base_bitrate(case.width, case.height) as f32;
    let ratio = (target_kbps as f32 + 0.5) / base;

    let mut enc = VpxEncoder::new(
        EncoderCfg::VPX(VpxEncoderConfig {
            width: case.width,
            height: case.height,
            quality: ratio,
            codec: VpxVideoCodecId::VP9,
            keyframe_interval: None,
        }),
        false,
    )
    .expect("vpx encoder");
    let actual = enc.bitrate();
    assert_eq!(
        actual, target_kbps,
        "encoder target {actual} kbps does not match model target {target_kbps} kbps"
    );

    let mut dec = VpxDecoder::new(VpxDecoderConfig {
        codec: VpxVideoCodecId::VP9,
    })
    .expect("vpx decoder");

    let fmt = enc.yuvfmt();
    let scene = Scene::new(case.width as usize, case.height as usize, &fmt, case.motion);
    let (w, h) = (case.width as usize, case.height as usize);

    let mut src = Vec::new();
    let mut decoded = vec![0u8; w * h];
    let mut have_decoded = false;

    let mut encode_ms = Vec::with_capacity(case.measured);
    let mut decode_ms = Vec::with_capacity(case.measured);
    let mut psnrs = Vec::with_capacity(case.measured);
    let mut ssims = Vec::with_capacity(case.measured);
    let mut total_bytes = 0usize;
    let mut dropped = 0usize;

    for i in 0..case.warmup + case.measured {
        scene.frame(i, &mut src);
        let pts = (i as i64 * 1000) / case.fps as i64;

        // `encode` then `flush`, exactly as `EncoderApi::encode_to_message`
        // does: VP9's default config carries `g_lag_in_frames = 25`, so without
        // the flush nothing comes out for the first 25 frames. Production pays
        // for both calls, so both are timed.
        let t0 = Instant::now();
        let mut packets: Vec<Vec<u8>> = enc
            .encode(pts, &src, STRIDE_ALIGN)
            .expect("encode")
            .map(|f| f.data.to_vec())
            .collect();
        packets.extend(enc.flush().expect("flush").map(|f| f.data.to_vec()));
        let enc_elapsed = t0.elapsed().as_secs_f64() * 1000.0;

        let bytes: usize = packets.iter().map(|p| p.len()).sum();

        let t1 = Instant::now();
        let mut got_frame = false;
        for pkt in &packets {
            for img in dec.decode(pkt).expect("decode") {
                let planes = img.planes();
                let strides = img.stride();
                let (iw, ih) = (img.width().min(w), img.height().min(h));
                for r in 0..ih {
                    let row = unsafe {
                        std::slice::from_raw_parts(planes[0].add(r * strides[0] as usize), iw)
                    };
                    decoded[r * w..r * w + iw].copy_from_slice(row);
                }
                got_frame = true;
                have_decoded = true;
            }
        }
        let dec_elapsed = t1.elapsed().as_secs_f64() * 1000.0;

        if i < case.warmup {
            continue;
        }

        assert!(
            have_decoded,
            "decoder produced nothing during the measured window for {:?}",
            case
        );
        if !got_frame {
            // libvpx dropped this frame; the viewer keeps seeing the previous
            // one, so that is what the source frame is scored against.
            dropped += 1;
        }
        total_bytes += bytes;
        encode_ms.push(enc_elapsed);
        decode_ms.push(dec_elapsed);
        psnrs.push(psnr_y(&src, scene.stride_y, &decoded, w, w, h));
        ssims.push(ssim_y(&src, scene.stride_y, &decoded, w, w, h));
    }

    let seconds = case.measured as f64 / case.fps as f64;
    let kbits = total_bytes as f64 * 8.0 / 1000.0;
    Measurement {
        target_kbps,
        achieved_kbps: kbits / seconds,
        kbit_per_frame: kbits / case.measured as f64,
        psnr_db: mean(&psnrs),
        ssim: mean(&ssims),
        encode_ms_mean: mean(&encode_ms),
        encode_ms_p95: p95(&encode_ms),
        decode_ms_mean: mean(&decode_ms),
        dropped,
    }
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

/// Total printed width of a table row, so the rules line up with it.
const ROW_WIDTH: usize = 128;

fn header() -> String {
    format!(
        "  {:<11} {:>3}  {:<9} {:<7} {:<8} | {:>9} {:>9} {:>9} {:>8} {:>8} | {:>7} {:>8} {:>7} {:>5}",
        "resolution",
        "fps",
        "quality",
        "motion",
        "model",
        "tgt kbps",
        "got kbps",
        "kbit/frm",
        "PSNR dB",
        "SSIM",
        "enc ms",
        "enc p95",
        "dec ms",
        "drop",
    )
}

fn rule() -> String {
    "-".repeat(ROW_WIDTH)
}

/// One-minute load average. Worth printing next to any timing: a busy host both
/// slows the encoder down and, through `codec_thread_num`, hands it fewer
/// threads, so timings taken under load are not comparable with idle ones.
fn load_average_one() -> f64 {
    let mut s = System::new();
    s.refresh_cpu_usage();
    s.load_average().one
}

fn print_pair(case: Case, legacy: &Measurement, current: &Measurement) {
    let res = format!("{}x{}", case.width, case.height);
    for (model, m) in [(Model::Legacy, legacy), (Model::Current, current)] {
        let first = model == Model::Legacy;
        println!(
            "  {:<11} {:>3}  {:<9} {:<7} {:<8} | {:>9} {:>9.0} {:>9.1} {:>8.2} {:>8.4} | {:>7.2} {:>8.2} {:>7.2} {:>5}",
            if first { res.clone() } else { String::new() },
            if first { case.fps.to_string() } else { String::new() },
            if first { quality_label(case.quality).to_string() } else { String::new() },
            if first { case.motion.label().to_string() } else { String::new() },
            model.label(),
            m.target_kbps,
            m.achieved_kbps,
            m.kbit_per_frame,
            m.psnr_db,
            m.ssim,
            m.encode_ms_mean,
            m.encode_ms_p95,
            m.decode_ms_mean,
            m.dropped,
        );
    }
    let pct = |a: f64, b: f64| if b > 0.0 { (a / b - 1.0) * 100.0 } else { 0.0 };
    println!(
        "  {:<11} {:>3}  {:<9} {:<7} {:<8} | {:>8.0}% {:>8.0}% {:>8.0}% {:>+8.2} {:>+8.4} | {:>6.0}%",
        "",
        "",
        "",
        "",
        "delta",
        pct(current.target_kbps as f64, legacy.target_kbps as f64),
        pct(current.achieved_kbps, legacy.achieved_kbps),
        pct(current.kbit_per_frame, legacy.kbit_per_frame),
        current.psnr_db - legacy.psnr_db,
        current.ssim - legacy.ssim,
        pct(current.encode_ms_mean, legacy.encode_ms_mean),
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// PSNR/SSIM may dip below legacy by at most this much before it counts as a
/// regression. Both are well inside run-to-run noise for a deterministic
/// source; they exist only so exact ties cannot fail on float wobble.
const PSNR_EPS: f64 = 0.05;
const SSIM_EPS: f64 = 0.0005;

const RESOLUTIONS: &[(u32, u32)] = &[(1280, 720), (1920, 1080), (2560, 1440)];
const FRAME_RATES: &[u32] = &[30, 60, 120];
const QUALITIES: &[Quality] = &[Quality::Low, Quality::Balanced, Quality::Best];

const FULL_WARMUP: usize = 8;
const FULL_MEASURED: usize = 32;
const SMOKE_WARMUP: usize = 4;
const SMOKE_MEASURED: usize = 8;

fn requested_work_duration() -> Result<Option<Duration>, String> {
    let Some(raw) = env::var_os("CAMELLIA_PERFORMANCE_WORK_SECONDS") else {
        return Ok(None);
    };
    let raw = raw
        .to_str()
        .ok_or_else(|| "CAMELLIA_PERFORMANCE_WORK_SECONDS must be UTF-8".to_owned())?;
    let seconds = raw
        .parse::<u64>()
        .map_err(|_| "CAMELLIA_PERFORMANCE_WORK_SECONDS must be an integer".to_owned())?;
    if raw != seconds.to_string() || !(1..=60).contains(&seconds) {
        return Err(
            "CAMELLIA_PERFORMANCE_WORK_SECONDS must be a canonical integer in 1..60".to_owned(),
        );
    }
    Ok(Some(Duration::from_secs(seconds)))
}

fn case(
    width: u32,
    height: u32,
    fps: u32,
    quality: Quality,
    motion: Motion,
    model: Model,
    warmup: usize,
    measured: usize,
) -> Case {
    Case {
        width,
        height,
        fps,
        quality,
        motion,
        model,
        warmup,
        measured,
    }
}

/// Model-only check, no encoding: the per-frame bit budget must not collapse
/// when the session speeds up.
#[test]
fn per_frame_budget_survives_high_frame_rates() {
    for &(w, h) in RESOLUTIONS {
        for &q in QUALITIES {
            let per_frame = |fps: u32| current_kbps(w, h, fps, q) as f64 / fps as f64;
            let ratio = per_frame(120) / per_frame(30);
            assert!(
                ratio > 0.45,
                "current model starves 120fps at {w}x{h} {}: {:.3} of the 30fps per-frame budget",
                quality_label(q),
                ratio
            );

            let legacy_per_frame = |fps: u32| legacy_kbps(w, h, q) as f64 / fps as f64;
            let legacy_ratio = legacy_per_frame(120) / legacy_per_frame(30);
            assert!(
                legacy_ratio < 0.3,
                "legacy model was supposed to collapse to ~25%, got {:.3}",
                legacy_ratio
            );
            assert!(
                ratio > legacy_ratio,
                "current model must retain more per-frame budget than legacy"
            );
        }
    }
}

/// Default smoke subset: one real encode/decode cell per model, small enough to
/// stay in the normal `cargo test` budget even in a debug build.
#[test]
fn smoke_quality_harness_720p30_balanced() {
    let (w, h, fps, q, motion) = (1280, 720, 30, Quality::Balanced, Motion::Light);
    let legacy = run_case(case(
        w,
        h,
        fps,
        q,
        motion,
        Model::Legacy,
        SMOKE_WARMUP,
        SMOKE_MEASURED,
    ));
    let current = run_case(case(
        w,
        h,
        fps,
        q,
        motion,
        Model::Current,
        SMOKE_WARMUP,
        SMOKE_MEASURED,
    ));

    println!("{}", header());
    println!("{}", rule());
    print_pair(
        case(
            w,
            h,
            fps,
            q,
            motion,
            Model::Legacy,
            SMOKE_WARMUP,
            SMOKE_MEASURED,
        ),
        &legacy,
        &current,
    );

    for (name, m) in [("legacy", &legacy), ("current", &current)] {
        assert!(
            m.achieved_kbps > 0.0,
            "{}: encoder produced no bytes at all",
            name
        );
        assert!(
            m.psnr_db > 20.0 && m.psnr_db < 99.0,
            "{name}: implausible PSNR {:.2} dB - the harness is comparing the wrong pixels",
            m.psnr_db
        );
        assert!(
            m.ssim > 0.5 && m.ssim <= 1.0,
            "{name}: implausible SSIM {:.4}",
            m.ssim
        );
        assert!(m.decode_ms_mean > 0.0, "{}: nothing was decoded", name);
    }

    assert!(
        current.psnr_db >= legacy.psnr_db - PSNR_EPS,
        "current model lost PSNR at 720p30 Balanced: {:.2} vs {:.2} dB",
        current.psnr_db,
        legacy.psnr_db
    );
    assert!(
        current.ssim >= legacy.ssim - SSIM_EPS,
        "current model lost SSIM at 720p30 Balanced: {:.4} vs {:.4}",
        current.ssim,
        legacy.ssim
    );
}

/// Machine-readable PR performance observation. The surrounding shared
/// collector launches this ignored test repeatedly and owns warmup/sample
/// policy; this function measures only the real production VP9 path.
#[test]
#[ignore = "run through the shared paired performance collector"]
fn performance_contract_observation() {
    let output = PathBuf::from(
        env::var_os("CAMELLIA_PERFORMANCE_OBSERVATION_FILE")
            .expect("CAMELLIA_PERFORMANCE_OBSERVATION_FILE is required"),
    );
    assert!(
        output.is_absolute(),
        "performance observation path must be absolute"
    );

    let requested_duration = requested_work_duration().expect("valid bounded work duration");
    let started = Instant::now();
    let mut measurements = Vec::new();
    loop {
        measurements.push(run_case(case(
            1280,
            720,
            30,
            Quality::Balanced,
            Motion::Light,
            Model::Current,
            SMOKE_WARMUP,
            SMOKE_MEASURED,
        )));
        if requested_duration.is_none_or(|duration| started.elapsed() >= duration) {
            break;
        }
    }
    let average = |value: fn(&Measurement) -> f64| {
        measurements.iter().map(value).sum::<f64>() / measurements.len() as f64
    };
    let decode_ms_mean = average(|measurement| measurement.decode_ms_mean);
    let dropped_frames = average(|measurement| measurement.dropped as f64);
    let encode_ms_p95 = average(|measurement| measurement.encode_ms_p95);
    let encoded_bytes_per_second = average(|measurement| measurement.achieved_kbps * 125.0);
    let psnr_db = average(|measurement| measurement.psnr_db);
    let ssim = average(|measurement| measurement.ssim);
    for (name, value) in [
        ("decode_ms_mean", decode_ms_mean),
        ("encode_ms_p95", encode_ms_p95),
        ("encoded_bytes_per_second", encoded_bytes_per_second),
        ("psnr_db", psnr_db),
        ("ssim", ssim),
    ] {
        assert!(
            value.is_finite() && value > 0.0,
            "{} is not a finite positive observation",
            name
        );
    }
    assert!(
        dropped_frames.is_finite() && dropped_frames >= 0.0,
        "dropped_frames is not a finite non-negative observation"
    );

    let document = json!({
        "metrics": {
            "decode_ms_mean": {
                "direction": "lower",
                "unit": "ms",
                "value": decode_ms_mean,
            },
            "dropped_frames": {
                "direction": "lower",
                "unit": "count",
                "value": dropped_frames,
            },
            "encode_ms_p95": {
                "direction": "lower",
                "unit": "ms",
                "value": encode_ms_p95,
            },
            "encoded_bytes_per_second": {
                "direction": "lower",
                "unit": "bytes_per_second",
                "value": encoded_bytes_per_second,
            },
            "psnr_db": {
                "direction": "higher",
                "unit": "db",
                "value": psnr_db,
            },
            "ssim": {
                "direction": "higher",
                "unit": "ratio",
                "value": ssim,
            },
        },
        "scenario": "client-vp9-quality-v1",
        "schema": "camellia-performance-observation-v1",
    });
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(output)
        .expect("create exclusive performance observation");
    let mut writer = BufWriter::new(file);
    to_writer(&mut writer, &document).expect("write performance observation");
    writer
        .write_all(b"\n")
        .expect("finish performance observation");
    writer.flush().expect("flush performance observation");
    writer
        .get_ref()
        .sync_all()
        .expect("sync performance observation");
}

/// Full comparison matrix. Slow on purpose - run it explicitly:
///
/// ```text
/// cargo test -p scrap --features linux-pkg-config --release -- --ignored --nocapture bitrate_model_matrix
/// ```
#[test]
#[ignore = "full encode/decode matrix, minutes long; run with --release --ignored --nocapture"]
fn bitrate_model_matrix() {
    let started = Instant::now();
    println!();
    println!("=====================================================================================================================");
    println!(" Camellia bitrate model: legacy vs current, VP9 software, real encode/decode");
    println!(
        " host: {} logical cpus, codec threads {}, load average {:.2}; {} warmup + {} measured frames per cell; matrix motion = {}",
        num_cpus::get(),
        codec_thread_num(64),
        load_average_one(),
        FULL_WARMUP,
        FULL_MEASURED,
        Motion::Light.label(),
    );
    println!(" legacy: old_base(w,h) * old_ratio (no fps term)   current: base_bitrate(w,h) * quality.ratio() * fps_bitrate_scale(fps)");
    println!("=====================================================================================================================");
    println!("{}", header());
    println!("{}", rule());

    let mut quality_regressions: Vec<String> = Vec::new();
    let mut realtime_misses: Vec<String> = Vec::new();
    let mut realtime_1080p60: Option<Measurement> = None;

    for &(w, h) in RESOLUTIONS {
        for &fps in FRAME_RATES {
            for &q in QUALITIES {
                let legacy_case = case(
                    w,
                    h,
                    fps,
                    q,
                    Motion::Light,
                    Model::Legacy,
                    FULL_WARMUP,
                    FULL_MEASURED,
                );
                let current_case = Case {
                    model: Model::Current,
                    ..legacy_case
                };
                let legacy = run_case(legacy_case);
                let current = run_case(current_case);
                print_pair(legacy_case, &legacy, &current);

                if w == 1920 && fps == 60 && q == Quality::Balanced {
                    realtime_1080p60 = Some(current);
                }
                let interval = 1000.0 / fps as f64;
                if current.encode_ms_mean >= interval {
                    realtime_misses.push(format!(
                        "{w}x{h} {fps}fps {:<8} mean encode {:.2} ms vs {:.2} ms interval",
                        quality_label(q),
                        current.encode_ms_mean,
                        interval
                    ));
                }
                if current.psnr_db < legacy.psnr_db - PSNR_EPS {
                    quality_regressions.push(format!(
                        "{w}x{h} {fps}fps {:<8} PSNR {:.2} < legacy {:.2} dB",
                        quality_label(q),
                        current.psnr_db,
                        legacy.psnr_db
                    ));
                }
                if current.ssim < legacy.ssim - SSIM_EPS {
                    quality_regressions.push(format!(
                        "{w}x{h} {fps}fps {:<8} SSIM {:.4} < legacy {:.4}",
                        quality_label(q),
                        current.ssim,
                        legacy.ssim
                    ));
                }
            }
        }
        println!("{}", rule());
    }

    // Motion sweep: the matrix above runs at light motion, which is the common
    // case; heavy motion is where a starved per-frame budget actually shows.
    println!();
    println!(" motion sweep @ 1920x1080 Balanced");
    println!("{}", header());
    println!("{}", rule());
    for &motion in &[Motion::Static, Motion::Light, Motion::Heavy] {
        for &fps in &[30u32, 120] {
            let legacy_case = case(
                1920,
                1080,
                fps,
                Quality::Balanced,
                motion,
                Model::Legacy,
                FULL_WARMUP,
                FULL_MEASURED,
            );
            let current_case = Case {
                model: Model::Current,
                ..legacy_case
            };
            let legacy = run_case(legacy_case);
            let current = run_case(current_case);
            print_pair(legacy_case, &legacy, &current);
            if current.psnr_db < legacy.psnr_db - PSNR_EPS {
                quality_regressions.push(format!(
                    "1920x1080 {fps}fps Balanced motion={} PSNR {:.2} < legacy {:.2} dB",
                    motion.label(),
                    current.psnr_db,
                    legacy.psnr_db
                ));
            }
            if current.ssim < legacy.ssim - SSIM_EPS {
                quality_regressions.push(format!(
                    "1920x1080 {fps}fps Balanced motion={} SSIM {:.4} < legacy {:.4}",
                    motion.label(),
                    current.ssim,
                    legacy.ssim
                ));
            }
        }
    }
    println!("{}", rule());
    println!(
        " matrix took {:.1}s, load average now {:.2}",
        started.elapsed().as_secs_f64(),
        load_average_one()
    );
    println!();

    // ---- assertions ----

    let rt = realtime_1080p60.expect("1080p60 Balanced cell was not measured");
    let interval_ms = 1000.0 / 60.0;
    println!(
        " realtime check @ 1920x1080 60fps Balanced (current model): mean encode {:.2} ms, p95 {:.2} ms, frame interval {:.2} ms",
        rt.encode_ms_mean, rt.encode_ms_p95, interval_ms
    );
    if realtime_misses.is_empty() {
        println!(" every current-model cell encoded inside its frame interval");
    } else {
        println!(
            " cells whose mean encode time exceeds their frame interval (current model, this host):"
        );
        for m in &realtime_misses {
            println!("   - {m}");
        }
    }
    if !quality_regressions.is_empty() {
        println!(" QUALITY REGRESSIONS vs legacy:");
        for r in &quality_regressions {
            println!("   - {r}");
        }
    } else {
        println!(" no configuration where the current model lost PSNR or SSIM vs legacy");
    }
    println!();

    assert!(
        quality_regressions.is_empty(),
        "current bitrate model loses quality against legacy in {} configuration(s):\n  {}",
        quality_regressions.len(),
        quality_regressions.join("\n  ")
    );

    assert!(
        rt.encode_ms_mean < interval_ms,
        "1080p60 Balanced cannot be encoded in real time on this host: mean {:.2} ms/frame \
         (p95 {:.2} ms) against a {:.2} ms frame interval, on {} logical cpus with {} codec \
         threads at load average {:.2}. Either encoding got more expensive, or this host cannot \
         sustain a 60fps 1080p software VP9 session - check the load average before blaming the \
         code, since codec_thread_num() cuts the encoder's thread count as load rises.",
        rt.encode_ms_mean,
        rt.encode_ms_p95,
        interval_ms,
        num_cpus::get(),
        codec_thread_num(64),
        load_average_one(),
    );
}
