package com.medut.generic.phone.call

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log

/**
 * Ringtone + vibration for an incoming call. A self-managed call rings itself:
 * the ring notification channel is silent so the two never double up. Follows
 * the phone's ringer mode, and the app's own "Silent" status.
 */
object Ringer {
    private const val TAG = "MedutRinger"
    private var ringtone: Ringtone? = null
    private var vibrator: Vibrator? = null
    private var silent = false

    fun start(context: Context, appSilent: Boolean) {
        stop()
        silent = appSilent
        if (appSilent) return
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        when (am.ringerMode) {
            AudioManager.RINGER_MODE_SILENT -> return
            AudioManager.RINGER_MODE_VIBRATE -> vibrate(context)
            else -> {
                vibrate(context)
                playTone(context)
            }
        }
    }

    /** The user switched to Silent while it is ringing. */
    fun setSilent(context: Context, appSilent: Boolean) {
        if (appSilent && !silent) stop()
        silent = appSilent
    }

    fun stop() {
        try {
            ringtone?.stop()
        } catch (_: Exception) {
        }
        ringtone = null
        vibrator?.cancel()
        vibrator = null
    }

    private fun playTone(context: Context) {
        try {
            val uri = RingtoneManager.getActualDefaultRingtoneUri(context, RingtoneManager.TYPE_RINGTONE)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            val r = RingtoneManager.getRingtone(context, uri) ?: return
            r.audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            if (Build.VERSION.SDK_INT >= 28) r.isLooping = true
            r.play()
            ringtone = r
        } catch (e: Exception) {
            Log.e(TAG, "ringtone failed", e)
        }
    }

    private fun vibrate(context: Context) {
        val v = if (Build.VERSION.SDK_INT >= 31) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        if (!v.hasVibrator()) return
        v.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 800, 800), 0))
        vibrator = v
    }
}
