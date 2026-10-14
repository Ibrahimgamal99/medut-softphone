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
import com.medut.generic.phone.engine.AccountCfg
import com.medut.generic.phone.engine.EngineConfig
import com.medut.generic.phone.engine.EngineLog
import com.medut.generic.phone.engine.PhoneEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * The `medut/native` channel between Flutter and [PhoneEngine].
 *
 * Flutter → native: accounts, settings, dialing, messages, your status,
 * presence targets, the logs, OS settings shortcuts.
 * Native → Flutter: `state` (registrations, calls, presence), `historyChanged`,
 * `notice`, and navigation requests (`openRoute`).
 *
 * Messages to Dart that arrive before Dart has installed its handler (a tap on
 * a notification that opened the app) are queued and flushed when Dart sends
 * `ready`.
 */
object NativeBridge {
    private const val TAG = "MedutBridge"
    private const val CHANNEL = "medut/native"

    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var messenger: BinaryMessenger? = null
    private var dartReady = false
    private val pending = ArrayDeque<Pair<String, Any?>>()

    @SuppressLint("StaticFieldLeak")
    private lateinit var appContext: Context

    /** Once per Flutter engine (MainActivity keeps one for the process). */
    fun attach(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        if (messenger === this.messenger) return
        this.messenger = messenger
        dartReady = false
        val ch = MethodChannel(messenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                val engine = PhoneEngine
                when (call.method) {
                    "ready" -> {
                        dartReady = true
                        result.success(engine.state())
                        flush()
                    }
                    "state" -> result.success(engine.state())
                    "getAccounts" -> result.success(engine.repo.all().map { jsonToMap(it.json) })
                    "setAccounts" -> {
                        val list = (call.argument<List<Map<String, Any?>>>("accounts") ?: emptyList())
                            .map { AccountCfg(EngineConfig.fromMap(it)) }
                        engine.setAccounts(list)
                        result.success(null)
                    }
                    "setConfig" -> {
                        engine.setConfig(EngineConfig.fromMap(call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()))
                        result.success(null)
                    }
                    "tryRegister" -> {
                        val acct = AccountCfg(EngineConfig.fromMap(call.argument<Map<String, Any?>>("account") ?: emptyMap<String, Any?>()))
                        val timeout = (call.argument<Number>("timeoutMs") ?: 8000).toLong()
                        engine.tryRegister(acct, timeout) { result.success(it) }
                    }
                    "cancelProbe" -> {
                        engine.cancelProbe(call.argument<String>("id") ?: "")
                        result.success(null)
                    }
                    "retry" -> {
                        engine.retryNow(call.argument<String>("id") ?: "")
                        result.success(null)
                    }
                    "dial" -> {
                        engine.dial(
                            call.argument<String>("number") ?: "",
                            call.argument<String>("accountId"),
                            call.argument<String>("name"),
                        )
                        result.success(null)
                    }
                    "sendMessage" -> result.success(
                        engine.sendMessage(
                            call.argument<String>("peer") ?: "",
                            call.argument<String>("body") ?: "",
                            call.argument<String>("accountId"),
                        ),
                    )
                    "queueCodes" -> {
                        engine.queueCodes(call.argument<List<Map<String, Any?>>>("codes") ?: emptyList())
                        result.success(null)
                    }
                    "setPresenceTargets" -> {
                        engine.setPresenceTargets(call.argument<List<String>>("targets") ?: emptyList())
                        result.success(null)
                    }
                    "getLog" -> result.success(
                        EngineLog.read(call.argument<String>("kind") ?: "conn", (call.argument<Number>("since") ?: 0).toLong()),
                    )
                    "openCallScreen" -> {
                        if (engine.calls.isNotEmpty()) CallActivity.open(appContext)
                        result.success(null)
                    }
                    "missedSeen" -> {
                        engine.missedSeen()
                        result.success(null)
                    }
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
                // Only navigation is worth replaying: state is pulled on ready.
                if (method == "openRoute") pending.addLast(method to args)
                return@post
            }
            ch.invokeMethod(method, args)
        }
    }

    private fun flush() {
        val ch = channel ?: return
        while (pending.isNotEmpty()) {
            val (m, a) = pending.removeFirst()
            ch.invokeMethod(m, a)
        }
    }

    private fun jsonToMap(o: JSONObject): Map<String, Any?> =
        o.keys().asSequence().associateWith { k ->
            when (val v = o.opt(k)) {
                is JSONObject -> jsonToMap(v)
                JSONObject.NULL -> null
                else -> v
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
