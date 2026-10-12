package com.medut.generic.phone

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.medut.generic.phone.call.CallNotifications
import com.medut.generic.phone.call.Ringer
import com.medut.generic.phone.service.MedutService
import com.medut.generic.phone.telecom.MedutTelecom

/**
 * One call snapshot, as pushed from Dart on every change. Dart owns the call;
 * native only draws it. Every push is a full snapshot, so the latest one is
 * always enough to render.
 */
class CallSnapshot(val raw: Map<String, Any?>) {
    val phase: String get() = raw["phase"] as? String ?: "idle"
    val callId: String get() = raw["callId"] as? String ?: ""
    val name: String get() = raw["name"] as? String ?: ""
    val number: String get() = raw["number"] as? String ?: ""
    val account: String get() = raw["account"] as? String ?: ""
    val status: String get() = raw["status"] as? String ?: ""
    val startedAt: Long get() = (raw["startedAt"] as? Number)?.toLong() ?: 0L
    val muted: Boolean get() = raw["muted"] == true
    val held: Boolean get() = raw["held"] == true
    val route: String get() = raw["route"] as? String ?: "earpiece"
    val bluetooth: Boolean get() = raw["bluetooth"] == true
    val recording: Boolean get() = raw["recording"] == true
    val silent: Boolean get() = raw["silent"] == true
    val canRecord: Boolean get() = raw["canRecord"] != false
    /** File path of the chosen ringtone, or "system". */
    val ringtone: String get() = raw["ringtone"] as? String ?: "system"
    val vibrate: Boolean get() = raw["vibrate"] != false

    @Suppress("UNCHECKED_CAST")
    val routes: List<Map<String, Any?>> get() = (raw["routes"] as? List<Map<String, Any?>>) ?: emptyList()
    val mos: String get() = raw["mos"] as? String ?: ""
    val quality: String get() = raw["quality"] as? String ?: ""
    val dark: Boolean get() = raw["dark"] == true
    val rtl: Boolean get() = raw["rtl"] == true

    @Suppress("UNCHECKED_CAST")
    val details: List<List<String>>
        get() = (raw["details"] as? List<Any?>)?.mapNotNull { row ->
            (row as? List<Any?>)?.map { it?.toString() ?: "" }
        } ?: emptyList()

    @Suppress("UNCHECKED_CAST")
    val second: Map<String, Any?>? get() = raw["second"] as? Map<String, Any?>

    @Suppress("UNCHECKED_CAST")
    private val labels: Map<String, Any?> get() = raw["labels"] as? Map<String, Any?> ?: emptyMap()

    /** Translated label from Dart, so native and Flutter share one string table. */
    fun label(key: String, fallback: String): String = labels[key] as? String ?: fallback

    val title: String get() = name.ifBlank { number }
    val isLive: Boolean get() = phase != "idle" && phase != "ended"
}

object CallState {
    private const val TAG = "MedutCallState"
    private val main = Handler(Looper.getMainLooper())
    private lateinit var appContext: Context

    @Volatile
    var latest: CallSnapshot = CallSnapshot(emptyMap())
        private set

    private val listeners = mutableSetOf<(CallSnapshot) -> Unit>()

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    fun addListener(l: (CallSnapshot) -> Unit) {
        listeners.add(l)
        l(latest)
    }

    fun removeListener(l: (CallSnapshot) -> Unit) {
        listeners.remove(l)
    }

    /** Called on the main thread with each snapshot from Dart. */
    fun update(raw: Map<String, Any?>) {
        val prev = latest
        val next = CallSnapshot(raw)
        latest = next
        val newCall = next.callId != prev.callId
        if (newCall || next.phase != prev.phase) {
            Log.d(TAG, "phase ${prev.phase} -> ${next.phase} (${next.callId})")
            onTransition(prev, next, newCall)
        }
        if (next.phase == "incoming") {
            Ringer.setSilent(appContext, next.silent)
            CallNotifications.showIncoming(appContext, next)
        }
        // Stats arrive every few seconds; only touch the service notification
        // when something it shows has changed.
        val serviceKey = "${next.callId}|${next.phase}|${next.title}|${next.startedAt}|${next.status}|${next.muted}"
        if (serviceKey != lastServiceKey) {
            lastServiceKey = serviceKey
            MedutService.sync(appContext)
        }
        listeners.toList().forEach { it(next) }
    }

    private var lastServiceKey = ""

    private fun onTransition(prev: CallSnapshot, next: CallSnapshot, newCall: Boolean) {
        when (next.phase) {
            "incoming" -> {
                if (newCall) {
                    if (!MedutTelecom.startIncoming(appContext, next)) {
                        // Telecom refused (no phone account on some OEMs): ring anyway.
                        CallNotifications.showIncoming(appContext, next)
                    }
                    Ringer.start(appContext, next.ringtone, next.vibrate, next.silent)
                }
            }
            "outgoing", "connecting" -> {
                if (newCall) MedutTelecom.startOutgoing(appContext, next)
                Ringer.stop()
                CallNotifications.cancelIncoming(appContext)
            }
            "active" -> {
                Ringer.stop()
                CallNotifications.cancelIncoming(appContext)
                MedutTelecom.setActive()
            }
            "held" -> MedutTelecom.setHeld(true)
            "ended", "idle" -> {
                Ringer.stop()
                CallNotifications.cancelIncoming(appContext)
                MedutTelecom.end()
            }
        }
        if (prev.phase == "held" && next.phase == "active") MedutTelecom.setHeld(false)
    }

    fun post(block: () -> Unit) = main.post(block)
}
