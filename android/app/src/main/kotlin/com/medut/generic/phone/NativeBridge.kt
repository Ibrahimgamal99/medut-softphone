package com.medut.generic.phone

import android.annotation.SuppressLint
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import com.medut.generic.phone.call.CallActivity
import com.medut.generic.phone.call.CallNotifications
import com.medut.generic.phone.service.MedutService
import com.medut.generic.phone.telecom.MedutTelecom
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The `medut/native` channel between Dart and the native shell.
 *
 * Dart → native: call snapshots, keep-alive on/off, OS settings shortcuts.
 * Native → Dart: button taps on the native call screen and notifications
 * (`callAction`), and navigation requests (`openRoute`).
 *
 * Messages to Dart that arrive before Dart has installed its handler (a tap on
 * a cold-start ring screen) are queued and flushed when Dart sends `ready`.
 */
object NativeBridge {
    private const val TAG = "MedutBridge"
    private const val CHANNEL = "medut/native"

    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var dartReady = false
    private val pending = ArrayDeque<Pair<String, Any?>>()

    @SuppressLint("StaticFieldLeak")
    private lateinit var appContext: Context

    fun attach(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        val ch = MethodChannel(messenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "ready" -> {
                        dartReady = true
                        flush()
                        result.success(null)
                    }
                    "callState" -> {
                        @Suppress("UNCHECKED_CAST")
                        CallState.update(call.arguments as? Map<String, Any?> ?: emptyMap())
                        result.success(null)
                    }
                    "openCallScreen" -> {
                        CallActivity.open(appContext)
                        result.success(null)
                    }
                    "keepAlive" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        MedutService.setKeepAlive(
                            appContext,
                            enabled,
                            call.argument<String>("title") ?: "Medut",
                            call.argument<String>("text") ?: "",
                        )
                        result.success(null)
                    }
                    "missedCalls" -> {
                        CallNotifications.showMissed(
                            appContext,
                            call.argument<Int>("count") ?: 1,
                            call.argument<String>("latest") ?: "",
                            call.argument<String>("title") ?: "Missed call",
                        )
                        result.success(null)
                    }
                    "clearMissed" -> {
                        CallNotifications.cancelMissed(appContext)
                        result.success(null)
                    }
                    "messageNotification" -> {
                        CallNotifications.showMessage(
                            appContext,
                            call.argument<String>("peer") ?: "",
                            call.argument<String>("title") ?: "",
                            call.argument<String>("body") ?: "",
                        )
                        result.success(null)
                    }
                    "setRingtone" -> result.success(null) // Android: sent in each call snapshot
                    "isBatteryExempt" -> result.success(isBatteryExempt())
                    "requestBatteryExemption" -> {
                        requestBatteryExemption()
                        result.success(null)
                    }
                    "canUseFullScreenIntent" -> result.success(canUseFullScreenIntent())
                    "openFullScreenIntentSettings" -> {
                        openFullScreenIntentSettings()
                        result.success(null)
                    }
                    // With a Telecom call up, audio routes go through Telecom;
                    // false tells Dart to route through the SDK instead.
                    "setRoute" -> {
                        val route = call.argument<String>("route") ?: "earpiece"
                        if (MedutTelecom.connection != null) {
                            MedutTelecom.setRoute(route)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    "pushToken" -> result.success(null) // iOS only (PushKit)
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.e(TAG, "${call.method} failed", e)
                result.error("native", e.message, null)
            }
        }
    }

    /** Send a message to Dart on the main thread; queued until Dart is ready. */
    fun toDart(method: String, args: Any? = null) {
        main.post {
            val ch = channel
            if (ch == null || !dartReady) {
                pending.addLast(method to args)
                return@post
            }
            ch.invokeMethod(method, args)
        }
    }

    fun action(action: String, extra: Map<String, Any?> = emptyMap()) {
        toDart("callAction", mapOf("action" to action, "callId" to CallState.latest.callId) + extra)
    }

    private fun flush() {
        val ch = channel ?: return
        while (pending.isNotEmpty()) {
            val (m, a) = pending.removeFirst()
            ch.invokeMethod(m, a)
        }
    }

    private fun isBatteryExempt(): Boolean {
        val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(appContext.packageName)
    }

    @SuppressLint("BatteryLife")
    private fun requestBatteryExemption() {
        if (isBatteryExempt()) return
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            .setData(Uri.parse("package:${appContext.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        appContext.startActivity(intent)
    }

    private fun canUseFullScreenIntent(): Boolean {
        if (Build.VERSION.SDK_INT < 34) return true
        val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return nm.canUseFullScreenIntent()
    }

    private fun openFullScreenIntentSettings() {
        if (Build.VERSION.SDK_INT < 34) return
        val intent = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT)
            .setData(Uri.parse("package:${appContext.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        appContext.startActivity(intent)
    }
}
