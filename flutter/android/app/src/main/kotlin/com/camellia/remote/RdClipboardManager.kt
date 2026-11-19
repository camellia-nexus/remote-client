package com.camellia.remote

import java.nio.ByteBuffer
import java.util.Timer
import java.util.TimerTask

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.Keep

import hbb.MessageOuterClass.ClipboardFormat
import hbb.MessageOuterClass.Clipboard
import hbb.MessageOuterClass.MultiClipboards

import ffi.FFI

class RdClipboardManager(private val clipboardManager: ClipboardManager) {
    companion object {
        const val MAX_BINDER_CLIPBOARD_BYTES: Int = 1024 * 1024 // 1MB Android Binder transaction hard limit
    }

    private val logTag = "RdClipboardManager"
    private val mainHandler = Handler(Looper.getMainLooper())
    private val supportedMimeTypes = arrayOf(
        ClipDescription.MIMETYPE_TEXT_PLAIN,
        ClipDescription.MIMETYPE_TEXT_HTML
    )

    // 1. Avoid listening to the same clipboard data updated by `rustUpdateClipboard`.
    // 2. Avoid sending the clipboard data before enabling client clipboard.
    //    1) Disable clipboard
    //    2) Copy text "a"
    //    3) Enable clipboard
    //    4) Switch to another app
    //    5) Switch back to the app
    //    6) "a" should not be sent to the client, because it's copied before enabling clipboard
    //
    // It's okay to that `rustEnableClientClipboard(false)` is called after `rustUpdateClipboard`,
    // though the `lastUpdatedClipData` will be set to null once.
    @Volatile
    private var lastUpdatedClipData: ClipData? = null
    @Volatile
    private var isClientEnabled = true
    @Volatile
    private var _isCaptureStarted = false

    val isCaptureStarted: Boolean
        get() = _isCaptureStarted

    fun checkPrimaryClip(isClient: Boolean) {
        val clipData = try {
            clipboardManager.primaryClip
        } catch (e: Exception) {
            Log.w(logTag, "Failed to getPrimaryClip: $e")
            null
        }

        if (clipData != null && clipData.itemCount > 0) {
            // Only handle the first item in the clipboard for now.
            val clip = clipData.getItemAt(0)
            // Ignore the `isClipboardDataEqual()` check if it's a host operation.
            // Because it's an action manually triggered by the user.
            if (isClient) {
                if (lastUpdatedClipData != null && isClipboardDataEqual(clipData, lastUpdatedClipData!!)) {
                    Log.d(logTag, "Clipboard data is the same as last update, ignore")
                    return
                }
            }
            val mimeTypeCount = clipData.description?.mimeTypeCount ?: 0
            val mimeTypes = mutableListOf<String>()
            for (i in 0 until mimeTypeCount) {
                clipData.description?.getMimeType(i)?.let { mimeTypes.add(it) }
            }
            var text: CharSequence? = null
            var html: String? = null
            if (isSupportedMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN)) {
                text = clip?.text
            }
            if (isSupportedMimeType(ClipDescription.MIMETYPE_TEXT_HTML)) {
                if (text == null) {
                    text = clip?.text
                }
                html = clip?.htmlText
            }
            var count = 0
            val clips = MultiClipboards.newBuilder()
            if (text != null) {
                val content = com.google.protobuf.ByteString.copyFromUtf8(text.toString())
                clips.addClipboards(Clipboard.newBuilder().setFormat(ClipboardFormat.Text).setContent(content).build())
                count++
            }
            if (html != null) {
                val content = com.google.protobuf.ByteString.copyFromUtf8(html)
                clips.addClipboards(Clipboard.newBuilder().setFormat(ClipboardFormat.Html).setContent(content).build())
                count++
            }
            if (count > 0) {
                val clipsBytes = clips.build().toByteArray()
                val isClientFlag = if (isClient) 1 else 0
                val clipsBuf = ByteBuffer.allocateDirect(clipsBytes.size + 1).apply {
                    put(isClientFlag.toByte())
                    put(clipsBytes)
                }
                clipsBuf.flip()
                lastUpdatedClipData = clipData
                Log.d(logTag, "${if (isClient) "client" else "host"}, send clipboard data to the remote")
                FFI.onClipboardUpdate(clipsBuf)
            }
        }
    }

    private fun isSupportedMimeType(mimeType: String): Boolean {
        return supportedMimeTypes.contains(mimeType)
    }

    private fun isClipboardDataEqual(left: ClipData, right: ClipData): Boolean {
        val leftDesc = left.description ?: return false
        val rightDesc = right.description ?: return false

        val leftMimes = (0 until leftDesc.mimeTypeCount).map { leftDesc.getMimeType(it) }.toSet()
        val rightMimes = (0 until rightDesc.mimeTypeCount).map { rightDesc.getMimeType(it) }.toSet()
        if (leftMimes != rightMimes) {
            return false
        }

        if (left.itemCount != right.itemCount) {
            return false
        }
        for (i in 0 until left.itemCount) {
            val leftItem = left.getItemAt(i)
            val rightItem = right.getItemAt(i)
            val leftText = leftItem?.text?.toString()
            val rightText = rightItem?.text?.toString()
            val leftHtml = leftItem?.htmlText
            val rightHtml = rightItem?.htmlText
            if (leftText != rightText || leftHtml != rightHtml) {
                return false
            }
        }
        return true
    }

    fun setCaptureStarted(started: Boolean) {
        _isCaptureStarted = started
    }

    @Keep
    fun rustEnableClientClipboard(enable: Boolean) {
        Log.d(logTag, "rustEnableClientClipboard: enable: $enable")
        isClientEnabled = enable
        lastUpdatedClipData = null
    }

    fun syncClipboard(isClient: Boolean) {
        Log.d(logTag, "syncClipboard: isClient: $isClient, isClientEnabled: $isClientEnabled")
        if (isClient && !isClientEnabled) {
            return
        }
        checkPrimaryClip(isClient)
    }

    @Keep
    fun rustUpdateClipboard(clips: ByteArray) {
        val multiClips = try {
            MultiClipboards.parseFrom(clips)
        } catch (e: Exception) {
            Log.w(logTag, "Failed to parse MultiClipboards protobuf: $e")
            return
        }

        val mimeTypes = mutableListOf<String>()
        var text: String? = null
        var html: String? = null
        for (clip in multiClips.clipboardsList) {
            when (clip.format) {
                ClipboardFormat.Text -> {
                    if (!mimeTypes.contains(ClipDescription.MIMETYPE_TEXT_PLAIN)) {
                        mimeTypes.add(ClipDescription.MIMETYPE_TEXT_PLAIN)
                    }
                    text = String(clip.content.toByteArray(), Charsets.UTF_8)
                }
                ClipboardFormat.Html -> {
                    if (!mimeTypes.contains(ClipDescription.MIMETYPE_TEXT_HTML)) {
                        mimeTypes.add(ClipDescription.MIMETYPE_TEXT_HTML)
                    }
                    html = String(clip.content.toByteArray(), Charsets.UTF_8)
                }
                ClipboardFormat.ImageRgba, ClipboardFormat.ImagePng -> {
                    // Image formats are not currently supported by Android clipboard bridge
                    Log.d(logTag, "Ignored unsupported image clipboard format: ${clip.format}")
                }
                else -> {
                    Log.w(logTag, "Unsupported clipboard format: ${clip.format}")
                }
            }
        }

        if (text == null && html == null) {
            Log.d(logTag, "No text or HTML content in clipboard update, ignore")
            return
        }

        // Measure text and HTML byte lengths to protect against Android Binder 1MB transaction buffer limit
        val textBytesLen = text?.toByteArray(Charsets.UTF_8)?.size ?: 0
        val htmlBytesLen = html?.toByteArray(Charsets.UTF_8)?.size ?: 0
        val totalBytes = textBytesLen + htmlBytesLen

        if (totalBytes > MAX_BINDER_CLIPBOARD_BYTES) {
            Log.w(logTag, "Clipboard content ($totalBytes bytes) exceeds 1MB Binder transaction limit, applying protection")
            if (text != null && textBytesLen <= MAX_BINDER_CLIPBOARD_BYTES) {
                // If text fits within 1MB but combined with HTML exceeds 1MB, drop HTML to safely preserve plain text
                Log.w(logTag, "Dropping HTML content to keep total clipboard size within 1MB Binder limit")
                html = null
                mimeTypes.remove(ClipDescription.MIMETYPE_TEXT_HTML)
            } else if (text != null && textBytesLen > MAX_BINDER_CLIPBOARD_BYTES) {
                // If text itself exceeds 1MB, drop HTML and smoothly truncate text to safe 1MB limit
                Log.w(logTag, "Truncating text clipboard content to 1MB Binder limit")
                html = null
                mimeTypes.remove(ClipDescription.MIMETYPE_TEXT_HTML)
                text = truncateUtf8(text, MAX_BINDER_CLIPBOARD_BYTES)
            } else {
                // Only HTML is present and exceeds 1MB; cannot be safely truncated without corrupting HTML
                Log.w(logTag, "Oversized HTML-only clipboard payload ($htmlBytesLen bytes) intercepted to prevent TransactionTooLargeException")
                return
            }
        }

        if (text == null && html == null) {
            Log.d(logTag, "No text or HTML content remaining after Binder limit check, ignore")
            return
        }
        if (mimeTypes.isEmpty()) {
            return
        }

        val clipDescription = ClipDescription("clipboard", mimeTypes.toTypedArray())
        val item = if (html == null) {
            ClipData.Item(text)
        } else {
            ClipData.Item(text ?: "", html)
        }
        val clipData = ClipData(clipDescription, item)

        mainHandler.post {
            try {
                lastUpdatedClipData = clipData
                clipboardManager.setPrimaryClip(clipData)
            } catch (e: Throwable) {
                Log.w(logTag, "Failed to setPrimaryClip: $e")
            }
        }
    }

    private fun truncateUtf8(str: String, maxBytes: Int): String {
        val bytes = str.toByteArray(Charsets.UTF_8)
        if (bytes.size <= maxBytes) return str
        var end = maxBytes
        // Back up over UTF-8 continuation bytes (10xxxxxx -> 0x80..0xBF)
        while (end > 0 && (bytes[end].toInt() and 0xC0) == 0x80) {
            end--
        }
        // If end landed on a multi-byte lead byte whose full character was truncated, back up 1 more
        if (end > 0 && (bytes[end - 1].toInt() and 0x80) != 0) {
            val lead = bytes[end - 1].toInt() and 0xFF
            val seqLen = when {
                (lead and 0xE0) == 0xC0 -> 2
                (lead and 0xF0) == 0xE0 -> 3
                (lead and 0xF8) == 0xF0 -> 4
                else -> 1
            }
            if ((end - 1) + seqLen > maxBytes) {
                end -= 1
            }
        }
        return String(bytes, 0, end, Charsets.UTF_8)
    }

    fun cleanup() {
        lastUpdatedClipData = null
        _isCaptureStarted = false
    }
}
