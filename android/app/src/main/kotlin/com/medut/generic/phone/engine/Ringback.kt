package com.medut.generic.phone.engine

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.util.Log
import com.medut.generic.phone.R

/**
 * The "brrng… brrng…" while the far end rings (180 Ringing), stopped the
 * moment the call connects, fails or ends. Voice-signalling audio attributes,
 * so it plays where the user is already listening, like a native dialer.
 */
object Ringback {
    private var player: MediaPlayer? = null

    fun start(context: Context) {
        if (player != null) return
        try {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            player = MediaPlayer.create(context, R.raw.ringback, attrs, 0)?.apply {
                isLooping = true
                start()
            }
        } catch (e: Exception) {
            Log.e("MedutRingback", "ringback failed", e)
            player = null
        }
    }

    fun stop() {
        val p = player ?: return
        player = null
        try {
            p.stop()
        } catch (_: Exception) {
        }
        p.release()
    }
}
