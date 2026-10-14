package com.medut.generic.phone.call

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log

/**
 * Ringtone + vibration for an incoming call. A self-managed call rings itself:
 * the ring notification channel is silent so the two never double up. Follows
 * the phone's ringer mode.
 */
object Ringer {
    private const val TAG = "MedutRinger"
    private var ringtone: Ringtone? = null
    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null

    /**
     * [source] is the ringtone the user picked in Medut: a file path (a bundled
     * tone copied out of the app, or their own file) or "system" for the
     * phone's ringtone. [vibrate] is Medut's own vibrate switch.
     */
    fun start(context: Context, source: String, vibrate: Boolean) {
        stop()
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        when (am.ringerMode) {
            AudioManager.RINGER_MODE_SILENT -> return
            AudioManager.RINGER_MODE_VIBRATE -> if (vibrate) vibrate(context)
            else -> {
                if (vibrate) vibrate(context)
                if (source == "system" || !playFile(context, source)) playTone(context)
            }
        }
    }

    private fun playFile(context: Context, path: String): Boolean = try {
        val mp = MediaPlayer()
        mp.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build(),
        )
        mp.setDataSource(context, Uri.fromFile(java.io.File(path)))
        mp.isLooping = true
        mp.setOnPreparedListener { it.start() }
        mp.prepareAsync()
        player = mp
        true
    } catch (e: Exception) {
        Log.e(TAG, "ringtone file failed, using the system one", e)
        false
    }

    fun stop() {
        try {
            ringtone?.stop()
        } catch (_: Exception) {
        }
        ringtone = null
        try {
            player?.stop()
        } catch (_: Exception) {
        }
        player?.release()
        player = null
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
