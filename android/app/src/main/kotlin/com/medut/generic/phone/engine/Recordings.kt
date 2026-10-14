package com.medut.generic.phone.engine

import android.content.Context
import java.io.File
import java.io.RandomAccessFile
import java.time.LocalDateTime

/** Call recordings: where they go, what they are called, and fixing their WAV header. */
object Recordings {
    /**
     * The folder Dart resolved for Settings → Recording (shared Recordings/Medut,
     * private, or custom), else the app's own recordings folder.
     */
    fun dir(context: Context, config: EngineConfig): File {
        val chosen = config.recordingDir
        if (chosen.isNotEmpty()) return File(chosen)
        return File(context.getExternalFilesDir(null) ?: context.filesDir, "Recordings")
    }

    /**
     * A recording's file name, the way the phone's own call recorder names
     * them: who (number, then name when there is one) and when.
     * `201 Sara_261013_182405.wav` (SipService.recordingName).
     */
    fun name(number: String, name: String, at: LocalDateTime = LocalDateTime.now()): String {
        fun two(v: Int) = v.toString().padStart(2, '0')
        val time = "${two(at.year % 100)}${two(at.monthValue)}${two(at.dayOfMonth)}_${two(at.hour)}${two(at.minute)}${two(at.second)}"
        val who = linkedSetOf(number.trim(), name.trim()).filter { it.isNotEmpty() }.joinToString(" ")
        val safe = who.replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001f]+"), "_").replace(Regex("^[_\\s]+|[_\\s]+$"), "")
        return "${safe.ifEmpty { "call" }}_$time.wav"
    }

    /**
     * Fixes the sizes in a WAV header written when recording started (data
     * size 0) but never finished, so players see the audio: the SDK closes a
     * recording without finishing it when the call ends under it.
     */
    fun repairWav(path: String) {
        if (path.isEmpty()) return
        val f = File(path)
        if (!f.exists()) return
        try {
            RandomAccessFile(f, "rw").use { raf ->
                val len = raf.length()
                if (len < 44) return
                val h = ByteArray(44)
                raf.seek(0)
                raf.readFully(h)
                fun tag(at: Int) = String(h, at, 4, Charsets.US_ASCII)
                if (tag(0) != "RIFF" || tag(8) != "WAVE" || tag(36) != "data") return
                fun u32(at: Int) = (h[at].toLong() and 0xff) or ((h[at + 1].toLong() and 0xff) shl 8) or
                    ((h[at + 2].toLong() and 0xff) shl 16) or ((h[at + 3].toLong() and 0xff) shl 24)
                val align = ((h[32].toInt() and 0xff) or ((h[33].toInt() and 0xff) shl 8)).coerceIn(1, 64)
                val data = ((len - 44) / align) * align
                if (u32(40) == data && u32(4) == 36 + data) return
                fun le(v: Long) = byteArrayOf((v and 0xff).toByte(), (v shr 8 and 0xff).toByte(),
                    (v shr 16 and 0xff).toByte(), (v shr 24 and 0xff).toByte())
                raf.seek(4)
                raf.write(le(36 + data))
                raf.seek(40)
                raf.write(le(data))
            }
        } catch (_: Exception) {
        }
    }

    /** Length of a WAV file from its header (byte rate) and size; null if unreadable. */
    fun wavSeconds(path: String): Int? {
        if (path.isEmpty()) return null
        val f = File(path)
        if (!f.exists()) return null
        return try {
            RandomAccessFile(f, "r").use { raf ->
                if (raf.length() < 44) return null
                val h = ByteArray(44)
                raf.readFully(h)
                val byteRate = (h[28].toInt() and 0xff) or ((h[29].toInt() and 0xff) shl 8) or
                    ((h[30].toInt() and 0xff) shl 16) or ((h[31].toInt() and 0xff) shl 24)
                if (byteRate <= 0) null else ((raf.length() - 44) / byteRate).toInt()
            }
        } catch (_: Exception) {
            null
        }
    }
}
