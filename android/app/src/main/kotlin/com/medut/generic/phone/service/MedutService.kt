package com.medut.generic.phone.service

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.medut.generic.phone.CallState
import com.medut.generic.phone.call.CallNotifications

/**
 * Keeps the process — and with it the PhoneEngine that drives SIP — alive:
 *
 *  - while "Stay reachable" is on: a quiet notification, the SIP registration
 *    stays up and the PBX can ring this phone at any time;
 *  - during a call: the ongoing-call card, so the call survives the app being
 *    closed and keeps the microphone in the background.
 *
 * START_STICKY: if Android kills us anyway, it restarts the service, which
 * restarts the process, the engine (MedutApp), and the registration.
 */
class MedutService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        running = true
        if (!update()) {
            // Started with startForegroundService, so it must go foreground
            // even when the call it was started for has already ended (a ring
            // turned away in a second): stopping first kills the app.
            start(CallNotifications.service(this, "Medut", ""), keepAliveTypes())
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    /** Re-posts the right notification; false when nothing needs the service. */
    private fun update(): Boolean {
        val s = CallState.latest
        val prefs = prefs(this)
        val keepAlive = prefs.getBoolean(KEY_ENABLED, false)
        return when {
            s.isLive && s.phase != "incoming" ->
                start(CallNotifications.ongoing(this, s), callTypes())
            keepAlive || s.phase == "incoming" ->
                start(
                    CallNotifications.service(
                        this,
                        prefs.getString(KEY_TITLE, "Medut") ?: "Medut",
                        prefs.getString(KEY_TEXT, "") ?: "",
                    ),
                    keepAliveTypes(),
                )
            else -> false
        }
    }

    /** Tries each foreground-service type in turn: some are refused depending
     *  on API level and on what the app is doing at that moment. */
    private fun start(n: Notification, types: List<Int>): Boolean {
        for (t in types) {
            try {
                ServiceCompat.startForeground(this, CallNotifications.ID_SERVICE, n, t)
                return true
            } catch (e: Exception) {
                Log.w(TAG, "startForeground type=$t refused: ${e.message}")
            }
        }
        return false
    }

    private fun keepAliveTypes(): List<Int> = when {
        Build.VERSION.SDK_INT >= 34 -> listOf(ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        Build.VERSION.SDK_INT >= 29 -> listOf(ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else -> listOf(0)
    }

    private fun callTypes(): List<Int> = when {
        Build.VERSION.SDK_INT >= 30 -> listOf(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
        ) + keepAliveTypes()
        Build.VERSION.SDK_INT >= 29 -> listOf(ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL) + keepAliveTypes()
        else -> listOf(0)
    }

    companion object {
        private const val TAG = "MedutService"
        private const val PREFS = "medut_service"
        private const val KEY_ENABLED = "keep_alive"
        private const val KEY_TITLE = "title"
        private const val KEY_TEXT = "text"

        @Volatile
        var running = false
            private set

        private fun prefs(context: Context) =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        fun keepAliveEnabled(context: Context) = prefs(context).getBoolean(KEY_ENABLED, false)

        fun setKeepAlive(context: Context, enabled: Boolean, title: String, text: String) {
            prefs(context).edit()
                .putBoolean(KEY_ENABLED, enabled)
                .putString(KEY_TITLE, title)
                .putString(KEY_TEXT, text)
                .apply()
            sync(context)
        }

        /** Starts, updates or stops the service to match the current state. */
        fun sync(context: Context) {
            val s = CallState.latest
            val needed = keepAliveEnabled(context) || s.isLive
            if (!needed) {
                if (running) context.stopService(Intent(context, MedutService::class.java))
                return
            }
            try {
                ContextCompat.startForegroundService(context, Intent(context, MedutService::class.java))
            } catch (e: Exception) {
                // Android 12+ refuses a start from the background outside the
                // allowed windows (boot, FCM, a visible activity). It is retried
                // on the next state change.
                Log.w(TAG, "start refused: ${e.message}")
            }
        }
    }
}
