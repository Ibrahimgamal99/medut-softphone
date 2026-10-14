package com.medut.generic.phone.engine

import android.app.Activity
import android.app.Application
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.ContactsContract
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log
import android.widget.Toast
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.medut.generic.phone.CallState
import com.medut.generic.phone.MainActivity
import com.medut.generic.phone.NativeBridge
import com.medut.generic.phone.call.CallActivity
import com.medut.generic.phone.call.CallNotifications
import com.medut.generic.phone.service.MedutService
import dev.medut.Account
import dev.medut.AecMode
import dev.medut.Call
import dev.medut.CallInfo
import dev.medut.JitterBufferType
import dev.medut.LogLevel
import dev.medut.MediaDirection
import dev.medut.MediaStats
import dev.medut.Medut
import dev.medut.MedutConfig
import dev.medut.MedutEvent
import dev.medut.NetworkStage
import dev.medut.OpusConfig
import dev.medut.PresenceStatus
import dev.medut.PushProvider
import dev.medut.QualityIssue
import dev.medut.RegistrationState
import dev.medut.android.AndroidOptions
import dev.medut.android.AudioRoute
import dev.medut.android.MedutAndroid
import dev.medut.android.MedutPush
import dev.medut.android.telecom.MedutTelecom
import dev.medut.android.telecom.TelecomOptions
import org.json.JSONObject
import java.util.Locale

enum class Phase { INCOMING, OUTGOING, ACTIVE, HELD;
    val wire get() = name.lowercase(Locale.ROOT)
}

/** A configured account and its live SDK object. */
class AccountRuntime(var cfg: AccountCfg, val signature: String) {
    var account: Account? = null
    /** off | registering | registered | reconnecting | failed */
    var status = "registering"
    var error = ""
    var retryInMs = 0L
    var sipCode = 0
    var mwiNew = 0L
    var mwiOld = 0L
    var mwiUrgent = 0L
    /** Registered by sign-in to see whether it works, not saved yet. */
    var probe = false
}

class ActiveCall(
    val id: String,
    val call: Call,
    val runtime: AccountRuntime,
    val incoming: Boolean,
    var number: String,
    var name: String,
    var phase: Phase,
) {
    val createdAt = System.currentTimeMillis()
    var answeredAt = 0L
    var muted = false
    var recording = false
    var recordingPath = ""
    var userDeclined = false
    var remoteRinging = false
    var stats: MediaStats? = null
    var crypto = ""

    /** Media path health: ok | reconnecting (network change, ICE restart) | weak (media stalled). */
    var link = "ok"

    /** SIP details, read while the call is up (they are gone once it ends). */
    var info: CallInfo? = null

    /** This phone hung up / declined (vs the other side or the network). */
    var endedLocally = false

    // Running sums for the call's average network figures (history grade).
    var rttSum = 0.0
    var jitterSum = 0.0
    var lossSum = 0.0
    var samples = 0
    var autoAnswer: Runnable? = null

    /** On the consult call of an attended transfer: the held call to hand over. */
    var transferOf: ActiveCall? = null

    /** On a call placed to follow the other side's transfer: the old leg. */
    var replaces: ActiveCall? = null

    /** A REFER was sent for this call and has not failed yet. */
    var transferring = false

    /** Hangs our leg up if the PBX took the transfer but never ended it. */
    var backstop: Runnable? = null

    /** The join was refused and the plain transfer to the same person tried instead. */
    var semiTried = false

    /** A status feature code (DND on, queue log-in…): kept out of the history. */
    var featureCode = false

    /** The ringing screen and ringtone are up (Telecom asked, or no Telecom). */
    var ringShown = false

    val title get() = name.ifEmpty { number }
}

/**
 * The phone: drives Medut-SDK for every account, call, transfer, recording
 * and message, with or without a Flutter engine. The native call screen
 * renders its snapshots ([CallState]); Flutter mirrors its state for the
 * Calls, People and Settings tabs over [NativeBridge].
 *
 * Everything runs on the main thread: SDK events are delivered there
 * (MedutAndroid's default), and so are the channel, the activities and Telecom.
 */
object PhoneEngine {
    private const val TAG = "MedutEngine"
    private const val PREFS = "medut_engine"

    lateinit var app: Context
        private set
    private val main = Handler(Looper.getMainLooper())

    var config = EngineConfig(JSONObject())
        private set
    lateinit var repo: AccountRepository
        private set
    private lateinit var history: HistoryWriter

    private var started = false
    var sdkUp = false
        private set

    val runtimes = LinkedHashMap<String, AccountRuntime>()
    val calls = mutableListOf<ActiveCall>()
    var focused: ActiveCall? = null
        private set
    val presence = HashMap<String, String>()
    private var presenceTargets: List<String> = emptyList()
    private val subscribed = HashSet<String>()

    /** Audio outputs the platform offers during a call, and the active one. */
    private var routes: List<AudioRoute> = emptyList()
    private var route = "earpiece"

    private var pushToken: String? = null
    private var pushProvider = PushProvider.NONE
    private var pushParam: String? = null

    /** Feature codes waiting to be dialed: (account id, code key, code). */
    private val codeQueue = ArrayDeque<Triple<String, String, String>>()
    private var codeCall: ActiveCall? = null

    /** Sign-in tries waiting for their registration to settle. */
    private val probeWaiters = HashMap<String, () -> Unit>()

    private var startedActivities = 0
    private var mainActivityResumed = false
    val foreground get() = startedActivities > 0

    private var proximity: PowerManager.WakeLock? = null
    private val names = HashMap<String, String>()

    // ── Start-up ────────────────────────────────────────────────────────────

    /** Application.onCreate: every process start, with or without UI. */
    fun start(context: Context) {
        if (started) return
        started = true
        app = context.applicationContext
        config = EngineConfig.load(app)
        repo = AccountRepository(app)
        history = HistoryWriter(app)
        CallNotifications.createChannels(app)
        CallState.init(app)
        (app as Application).registerActivityLifecycleCallbacks(lifecycle)
        forgetLegacyPhoneAccount()

        // The app draws its own incoming-call screen and ringtone; Telecom
        // only tells us when to show it. The ring waits for the INVITE.
        MedutTelecom.onShowIncomingCallUi = { call -> find(call)?.let(::showRing) }
        // Blocked, busy and Do not disturb are turned away before Telecom
        // hears of the call, so it never starts to ring.
        MedutTelecom.incomingCallFilter = { call -> refusal(call, call.remoteUri, call.remoteDisplayName) }
        // Mute from a headset button or a watch, and Telecom moving the audio.
        MedutTelecom.onCallAudioStateChanged = { call, muted, _ ->
            find(call)?.muted = muted
            refreshRoutes()
        }
        MedutTelecom.onOutgoingCallRefused = { notice(config.label("callFailed", "Couldn't place the call")) }
        MedutPush.ringOnPush = false
        loadPushToken()

        try {
            MedutAndroid.start(
                app,
                medutConfig(),
                AndroidOptions(
                    telecom = TelecomOptions(label = "Medut", incomingCallNotification = false),
                    restoreAccounts = false,
                ),
            )
            sdkUp = true
        } catch (t: Throwable) {
            Log.e(TAG, "SDK start failed", t)
            EngineLog.conn("SDK failed to start: ${t.message}")
        }
        if (sdkUp) {
            Medut.addListener { onEvent(it) }
            // On a network change, move calls to the new path (re-INVITE) and
            // never hang up because the move failed.
            runCatching { Medut.network.setHandoverPolicy(true, false) }
            applyAudioPrefs()
            runCatching { MedutAndroid.audioRoutes.addListener { onRoutesChanged() } }
        }
        applyAccounts()
        main.postDelayed(statusTick, 60_000)
        syncKeepAlive()
        push()
    }

    // Mobile tuning (SipService._medutConfig).
    private fun medutConfig() = MedutConfig(
        userAgent = "Medut/${versionName()} (android)",
        iceGatheringTimeoutMs = 800,
        statsIntervalMs = 2000,
        mediaStallMs = 3000,
        mosAlertThreshold = 3.5f,
        // DSCP EF for media, CS3 for signalling.
        dscpRtp = 46,
        dscpSip = 26,
        // Opus hardened for weak mobile networks.
        opus = OpusConfig(forwardErrorCorrection = true, discontinuousTransmission = true),
        opusExpectedLossPct = 10,
        // Fail a dead INVITE in 10 s, not RFC 3261's 32 s.
        sipTimerBMs = 10_000,
        regExpires = config.regExpires,
        keepaliveIntervalMs = config.keepaliveSec * 1000,
        logLevel = if (config.debugLogging) LogLevel.INFO else LogLevel.WARNING,
        traceSip = config.traceSip,
        aecMode = AecMode.entries.getOrElse(config.aecMode) { AecMode.WEBRTC },
        noiseSuppression = config.noiseSuppression,
        autoGainControl = config.autoGain,
    )

    private fun versionName(): String = runCatching {
        app.packageManager.getPackageInfo(app.packageName, 0).versionName
    }.getOrNull() ?: "1"

    private fun applyAudioPrefs() {
        if (!sdkUp) return
        runCatching {
            Medut.audio.setAecMode(AecMode.entries.getOrElse(config.aecMode) { AecMode.WEBRTC })
            Medut.audio.setNoiseSuppression(config.noiseSuppression)
            Medut.audio.setAutoGainControl(config.autoGain)
            Medut.audio.setJitterBufferType(JitterBufferType.ADAPTIVE)
            when (config.jitterMode) {
                "low" -> Medut.audio.setJitterBuffer(20, 150)
                "robust" -> Medut.audio.setJitterBuffer(60, 500)
            }
        }
    }

    /** The PhoneAccount the app registered before the SDK owned Telecom. */
    private fun forgetLegacyPhoneAccount() {
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getBoolean("legacyPhoneAccountGone", false)) return
        runCatching {
            val tm = app.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            tm.unregisterPhoneAccount(PhoneAccountHandle(
                ComponentName(app.packageName, "com.medut.generic.phone.telecom.MedutConnectionService"),
                "medut_self_managed",
            ))
        }
        prefs.edit().putBoolean("legacyPhoneAccountGone", true).apply()
    }

    private val lifecycle = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityStarted(a: Activity) {
            startedActivities++
            if (startedActivities == 1) publishStatus()
        }
        override fun onActivityStopped(a: Activity) {
            startedActivities = (startedActivities - 1).coerceAtLeast(0)
        }
        override fun onActivityResumed(a: Activity) {
            if (a is MainActivity) mainActivityResumed = true
        }
        override fun onActivityPaused(a: Activity) {
            if (a is MainActivity) mainActivityResumed = false
        }
        override fun onActivityCreated(a: Activity, b: Bundle?) {}
        override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
        override fun onActivityDestroyed(a: Activity) {}
    }

    private val statusTick = object : Runnable {
        override fun run() {
            publishStatus() // office hours may have started or ended
            main.postDelayed(this, 60_000)
        }
    }

    // ── Push (FCM) ──────────────────────────────────────────────────────────

    /** The last FCM token, so an account a push brings up registers with it at once. */
    private fun loadPushToken() {
        if (FirebaseApp.getApps(app).isEmpty()) return // no google-services.json: keep-alive only
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        pushParam = runCatching { FirebaseApp.getInstance().options.projectId }.getOrNull()
        prefs.getString("pushToken", null)?.let {
            pushToken = it
            pushProvider = PushProvider.FCM
        }
        runCatching {
            FirebaseMessaging.getInstance().token.addOnSuccessListener { t -> main.post { setPushToken(t) } }
        }.onFailure { Log.w(TAG, "FCM token: $it") }
    }

    /** A new FCM token (MedutFcmService.onNewToken, or the first one). */
    fun setPushToken(token: String?) {
        if (token == pushToken) return
        val hadProvider = pushProvider != PushProvider.NONE
        pushToken = token
        pushProvider = if (token == null) PushProvider.NONE else PushProvider.FCM
        app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("pushToken", token).apply()
        for (rt in runtimes.values.toList()) {
            if (!rt.cfg.push) continue
            if (hadProvider && token != null) runCatching { rt.account?.setPushToken(token) }
            else recreate(rt.cfg)
        }
    }

    // ── Settings and accounts from Flutter ──────────────────────────────────

    fun setConfig(j: JSONObject) {
        EngineConfig.save(app, j)
        config = EngineConfig(j)
        syncKeepAlive()
        publishStatus()
        applyAudioPrefs()
        scheduleApply() // ICE servers, relay and the codec order live on the accounts
        push()
    }

    fun setAccounts(list: List<AccountCfg>) {
        repo.replace(list)
        scheduleApply()
    }

    private val applyRunnable = Runnable { applyAccounts() }

    private fun scheduleApply() {
        main.removeCallbacks(applyRunnable)
        main.postDelayed(applyRunnable, 300)
    }

    private fun applyAccounts() {
        if (!sdkUp) {
            pushState()
            return
        }
        val wanted = repo.all().filter { it.enabled }.associateBy { it.id }
        // A tried account that has been saved is an ordinary account from now on.
        for ((id, rt) in runtimes) if (rt.probe && wanted.containsKey(id)) rt.probe = false
        for (id in runtimes.keys.toList()) {
            val rt = runtimes[id] ?: continue
            if (!wanted.containsKey(id) && !rt.probe && calls.none { it.runtime.cfg.id == id }) destroy(id)
        }
        for (c in wanted.values) {
            val rt = runtimes[c.id]
            if (rt == null || rt.signature != c.signature(config, pushProvider.name)) recreate(c) else rt.cfg = c
        }
        syncKeepAlive()
        syncSubscriptions()
        pushState()
    }

    private fun destroy(id: String) {
        val rt = runtimes.remove(id) ?: return
        runCatching {
            rt.account?.unregister()
            rt.account?.destroy()
        }
        subscribed.removeAll { it.startsWith("$id|") }
    }

    private fun recreate(c: AccountCfg) {
        if (calls.any { it.runtime.cfg.id == c.id }) return // never under a live call
        val wasProbe = runtimes[c.id]?.probe == true
        destroy(c.id)
        if (!sdkUp) return
        val rt = AccountRuntime(c, c.signature(config, pushProvider.name))
        rt.probe = wasProbe
        runtimes[c.id] = rt
        try {
            val acct = Medut.createAccount(c.toSdk(config, pushProvider, pushToken, pushParam))
            rt.account = acct
            for ((k, v) in c.headerPairs()) acct.addHeader(k, v)
            acct.register()
        } catch (e: Exception) {
            rt.status = "failed"
            rt.error = e.message ?: e.toString()
        }
    }

    /**
     * Registers [c] without saving it, to see whether it works: sign-in tries
     * TLS, TCP and UDP this way. A registration that succeeds keeps running,
     * so saving the same config afterwards adopts it. Anything else is torn down.
     */
    fun tryRegister(c: AccountCfg, timeoutMs: Long, done: (Map<String, Any?>) -> Unit) {
        if (!sdkUp) {
            done(mapOf("status" to "failed", "sipCode" to 0, "error" to "SIP stack not running"))
            return
        }
        probeWaiters.remove(c.id)?.invoke()
        runtimes[c.id]?.probe = true
        recreate(c)
        val rt = runtimes[c.id]
        if (rt == null) {
            cancelProbe(c.id)
            done(mapOf("status" to "failed", "sipCode" to 0, "error" to ""))
            return
        }
        rt.probe = true
        var finished = false
        lateinit var timeout: Runnable
        fun finish() {
            if (finished) return
            finished = true
            main.removeCallbacks(timeout)
            probeWaiters.remove(c.id)
            val status = if (runtimes[c.id] !== rt) "off" else rt.status // cancelled meanwhile
            if (status != "registered") cancelProbe(c.id)
            done(mapOf("status" to status, "sipCode" to rt.sipCode, "error" to rt.error))
        }
        timeout = Runnable { finish() } // still trying: no answer on this transport
        probeWaiters[c.id] = {
            if (rt.status == "registered" || rt.status == "failed" || rt.status == "reconnecting" ||
                runtimes[c.id] !== rt) finish()
        }
        main.postDelayed(timeout, timeoutMs)
        probeWaiters[c.id]?.invoke()
    }

    /** Drops a tried account that was not saved (failed, or the user left). */
    fun cancelProbe(id: String) {
        val rt = runtimes[id] ?: return
        if (!rt.probe || repo.byId(id) != null) return
        destroy(id)
        probeWaiters.remove(id)?.invoke()
        pushState()
    }

    fun retryNow(id: String) {
        runCatching { runtimes[id]?.account?.retryNow() }
    }

    private fun runtimeOf(a: Account?): AccountRuntime? =
        if (a == null) null else runtimes.values.firstOrNull { it.account === a }

    // ── SDK events ─────────────────────────────────────────────────────────

    private fun onEvent(e: MedutEvent) {
        when (e) {
            is MedutEvent.Registration -> onRegistration(e)
            is MedutEvent.MessageWaiting -> runtimeOf(e.account)?.let {
                it.mwiNew = e.newVoice
                it.mwiOld = e.oldVoice
                it.mwiUrgent = e.newUrgent
                pushState()
            }
            is MedutEvent.Message -> onMessage(e)
            is MedutEvent.Presence -> {
                presence[userPart(e.targetUri)] = e.status.name.lowercase(Locale.ROOT)
                pushState()
            }
            is MedutEvent.IncomingCall -> onIncoming(e)
            is MedutEvent.CallStateChanged -> onCallState(e)
            is MedutEvent.MediaStatsUpdate -> {
                val ac = e.call?.let(::find) ?: return
                ac.stats = e.stats
                if (ac.phase == Phase.ACTIVE || ac.phase == Phase.HELD) {
                    ac.rttSum += e.stats.rttMs
                    ac.jitterSum += e.stats.jitterMs
                    ac.lossSum += e.stats.lossPctRx
                    ac.samples++
                }
                push()
            }
            is MedutEvent.SdpNegotiation -> e.call?.let(::find)?.let { it.crypto = e.negotiatedCrypto ?: "" }
            is MedutEvent.TransferRequest -> onTransferRequest(e)
            is MedutEvent.TransferFailed -> onTransferFailed(e)
            is MedutEvent.Network -> {
                EngineLog.conn("network ${e.stage.name.lowercase(Locale.ROOT)}${if (e.localAddress.isNotEmpty()) " ${e.localAddress}" else ""}")
                val ac = e.call?.let(::find) ?: return
                val link = when (e.stage) {
                    NetworkStage.CALL_MIGRATING, NetworkStage.CALL_DEFERRED, NetworkStage.CALL_ICE_STALE -> "reconnecting"
                    NetworkStage.CALL_MIGRATED, NetworkStage.CALL_MIGRATE_ACCEPTED -> "ok"
                    NetworkStage.CALL_MIGRATION_FAILED, NetworkStage.CALL_ICE_FAILED -> "weak"
                    else -> ac.link
                }
                if (link != ac.link) {
                    ac.link = link
                    push()
                }
            }
            is MedutEvent.QualityAlert -> {
                val ac = e.call?.let(::find) ?: return
                if (e.issue == QualityIssue.MEDIA_STALL) {
                    ac.link = if (e.recovering) "ok" else "weak"
                    push()
                }
            }
            is MedutEvent.Log -> if (config.debugLogging) EngineLog.conn(e.message.trim())
            is MedutEvent.SipTrace ->
                EngineLog.sip("${if (e.direction == MediaDirection.TX) "→" else "←"} ${e.transport} ${e.remoteAddress}\n${e.message}")
            else -> {}
        }
    }

    private fun onRegistration(e: MedutEvent.Registration) {
        val rt = runtimeOf(e.account) ?: return
        val was = rt.status
        rt.status = when (e.state) {
            RegistrationState.REGISTERED -> "registered"
            RegistrationState.REGISTERING -> "registering"
            RegistrationState.RECONNECTING -> "reconnecting"
            RegistrationState.FAILED -> "failed"
            else -> "off"
        }
        rt.error = e.errorText ?: ""
        rt.retryInMs = e.retryDelayMs
        EngineLog.conn("${rt.cfg.label}: ${e.state.name.lowercase(Locale.ROOT)}" +
            (if (rt.error.isNotEmpty()) " — ${rt.error}" else "") +
            (if (e.retryDelayMs > 0) " (retry ${e.retryDelayMs / 1000}s)" else ""))
        rt.sipCode = Regex("\\b([3-6]\\d\\d)\\b").find(rt.error)?.groupValues?.get(1)?.toIntOrNull() ?: 0
        // Each refresh reports "registered" again: publish and subscribe only on arrival.
        if (rt.status == "registered" && was != "registered") {
            publishStatusFor(rt)
            syncSubscriptions()
        }
        probeWaiters[rt.cfg.id]?.invoke()
        syncKeepAlive()
        pushState()
    }

    private fun onMessage(e: MedutEvent.Message) {
        val rt = runtimeOf(e.account) ?: return
        val peer = userPart(e.fromUri)
        history.addMessage(rt.cfg.id, peer, e.body, outgoing = false)
        if (!foreground) {
            val who = nameFor(peer)
            CallNotifications.showMessage(app, peer, who.ifEmpty { peer }, e.body)
        }
        NativeBridge.toDart("historyChanged")
    }

    // ── Presence and your status ───────────────────────────────────────────

    private fun publishStatus() {
        for (rt in runtimes.values) if (rt.status == "registered") publishStatusFor(rt)
    }

    private fun publishStatusFor(rt: AccountRuntime) {
        val dnd = config.effectiveStatus() == "dnd"
        runCatching { rt.account?.publishPresence(if (dnd) PresenceStatus.CLOSED else PresenceStatus.OPEN) }
    }

    /** The extensions Flutter wants followed (presenceTargets in lib/core/people.dart). */
    fun setPresenceTargets(targets: List<String>) {
        presenceTargets = targets
        syncSubscriptions()
    }

    /** Follows [presenceTargets] on the default account. */
    private fun syncSubscriptions() {
        val def = repo.defaultAccount() ?: return
        val rt = runtimes[def.id] ?: return
        if (rt.status != "registered") return
        val want = presenceTargets.map { "${rt.cfg.id}|$it" }.toSet()
        for (key in subscribed.minus(want).toList()) {
            val (id, ext) = key.split('|', limit = 2)
            runtimes[id]?.let { o -> runCatching { o.account?.unsubscribePresence(uriFor(o.cfg, ext)) } }
            subscribed.remove(key)
        }
        for (key in want.minus(subscribed)) {
            runCatching { rt.account?.subscribePresence(uriFor(rt.cfg, key.substringAfter('|'))) }
            subscribed.add(key)
        }
    }

    /**
     * Status feature codes to dial (Flutter works out which, from the status
     * change): one after the other, as ordinary calls, so each PBX
     * announcement is heard. Each entry is {accountId, key, code}.
     */
    fun queueCodes(codes: List<Map<String, Any?>>) {
        for (c in codes) {
            val id = c["accountId"] as? String ?: continue
            val code = c["code"] as? String ?: continue
            codeQueue.addLast(Triple(id, c["key"] as? String ?: "", code))
        }
        publishStatus()
        dialNextCode()
    }

    /** Dials the next waiting feature code, once no call is up. */
    private fun dialNextCode() {
        if (codeCall != null || codeQueue.isEmpty() || calls.isNotEmpty()) return
        val (id, key, code) = codeQueue.removeFirst()
        EngineLog.conn("status code: $key $code")
        val ac = dial(code, id, config.label("code_$key", key))
        if (ac == null) {
            dialNextCode()
            return
        }
        ac.featureCode = true
        codeCall = ac
        // The PBX hangs up after its announcement; if it does not, we do.
        val backstop = Runnable { if (calls.contains(ac)) hangup(ac) }
        ac.backstop = backstop
        main.postDelayed(backstop, 20_000)
    }

    // ── Keep-alive (foreground service) ─────────────────────────────────────

    private var keepAliveShown = ""

    private fun syncKeepAlive() {
        val enabled = config.keepAlive && repo.all().any { it.enabled }
        val up = runtimes.values.count { it.status == "registered" && !it.probe }
        val title = config.label("appName", "Medut")
        val text = if (up == 0) config.label("keepAliveConnecting", "Connecting your accounts…")
        else config.label("keepAliveOn", "Ready for calls · {n} connected", "n" to "$up")
        // Registration refreshes come every few seconds: only a change is worth a re-post.
        val key = "$enabled|$title|$text"
        if (key == keepAliveShown) return
        keepAliveShown = key
        MedutService.setKeepAlive(app, enabled, title, text)
    }

    // ── Calls ──────────────────────────────────────────────────────────────

    private fun find(c: Call): ActiveCall? = calls.firstOrNull { it.call === c }

    private fun byId(id: String?): ActiveCall? = if (id.isNullOrEmpty()) null else calls.firstOrNull { it.id == id }

    private fun callIdOf(c: Call): String =
        runCatching { c.info().callId }.getOrDefault("").ifEmpty { System.nanoTime().toString() }

    /** Calls the incoming-call filter turned away, until their event arrives. */
    private val refused = HashSet<Call>()

    /**
     * Whether an incoming call is turned away, and with which SIP code:
     * 480 for an account we no longer have, 603 for a blocked number, 486
     * when two calls are already up or under Do not disturb (unless a
     * favourite or a repeat caller gets through; a call turned away by Do
     * not disturb still shows as missed). Null lets it ring.
     */
    private fun refusal(call: Call, fromUri: String, displayName: String?): Int? {
        val code = refusalCode(call, fromUri, displayName) ?: return null
        refused.add(call)
        return code
    }

    private fun refusalCode(call: Call, fromUri: String, displayName: String?): Int? {
        val rt = runtimeOf(call.account) ?: return 480
        val number = userPart(fromUri)
        if (config.blocked.contains(number)) {
            EngineLog.conn("blocked call from $number")
            return 603
        }
        if (calls.size >= 2) return 486
        if (config.effectiveStatus() == "dnd") {
            val fav = config.letFavourites && config.favourites.any { sameNumber(it, number) }
            val repeat = config.letRepeat && history.calledRecently(number)
            if (!fav && !repeat) {
                val shown = (displayName ?: "").trim()
                val name = nameFor(number).ifEmpty { if (shown == number) "" else shown }
                history.addCall(missedRow(rt, number, name))
                NativeBridge.toDart("historyChanged")
                // Turned away, but still a call you missed: say so.
                notifyMissed(name.ifEmpty { number })
                return 486
            }
        }
        return null
    }

    private fun onIncoming(e: MedutEvent.IncomingCall) {
        val call = e.call
        // Already turned away by the filter, before Telecom was told.
        if (refused.remove(call)) return
        // No Telecom (below API 26): the same rules, applied here.
        if (!MedutAndroid.isTelecomEnabled) {
            refusal(call, e.fromUri, e.displayName)?.let { code ->
                refused.remove(call)
                runCatching { call.reject(code, if (code == 603) "Decline" else if (code == 480) "Temporarily Unavailable" else "Busy Here") }
                return
            }
        }
        val rt = runtimeOf(e.account ?: call.account) ?: return
        val number = userPart(e.fromUri)
        val shown = (e.displayName ?: "").trim()
        val name = nameFor(number).ifEmpty { if (shown == number) "" else shown }

        val ac = ActiveCall(callIdOf(call), call, rt, true, number, name, Phase.INCOMING)
        calls.add(ac)
        // A second call while talking is "call waiting": the live one stays in front.
        if (focused == null) focused = ac
        if (MedutAndroid.isTelecomEnabled) {
            // Telecom says when to show it (onShowIncomingCallUi); ring anyway if it never does.
            main.postDelayed({ if (calls.contains(ac) && ac.phase == Phase.INCOMING && !ac.ringShown) showRing(ac) }, 2000)
        } else {
            showRing(ac)
        }
        push()
        pushState()
        // Auto-answer (not over another call). It still rings, so it can be declined.
        if (config.autoAnswer && focused === ac) {
            val r = Runnable { if (ac.phase == Phase.INCOMING && calls.contains(ac)) answer(ac) }
            ac.autoAnswer = r
            main.postDelayed(r, config.autoAnswerDelay * 1000L)
        }
    }

    private fun missedRow(rt: AccountRuntime, number: String, name: String) = ContentValues().apply {
        put("account_id", rt.cfg.id)
        put("account_name", rt.cfg.label)
        put("number", number)
        put("name", name)
        put("direction", "incoming")
        put("result", "missed")
        put("started_at", System.currentTimeMillis())
        put("duration", 0)
    }

    /**
     * The ringtone and the incoming-call notification, once Telecom asks for
     * them. Android shows that notification as a pop-up while the phone is
     * unlocked (in Medut or any other app) and its full-screen ringing screen
     * when the phone is locked or the screen is off, so the app never opens
     * the ringing screen itself.
     */
    private fun showRing(ac: ActiveCall) {
        if (ac.ringShown || ac.phase != Phase.INCOMING) return
        ac.ringShown = true
        push()
    }

    private fun onCallState(e: MedutEvent.CallStateChanged) {
        val ac = find(e.call) ?: return
        when (e.state) {
            dev.medut.CallState.RINGING -> {
                ac.remoteRinging = true
                if (!ac.incoming && config.ringback && focused === ac) Ringback.start(app)
            }
            dev.medut.CallState.ESTABLISHED -> {
                Ringback.stop()
                val first = ac.answeredAt == 0L
                ac.info = runCatching { ac.call.info() }.getOrNull() ?: ac.info
                if (first) initCallRoute()
                if (first) ac.answeredAt = System.currentTimeMillis()
                ac.phase = Phase.ACTIVE
                // We followed a transfer and the new party answered: the old leg goes.
                val old = ac.replaces
                ac.replaces = null
                if (old != null && calls.contains(old)) hangup(old)
                if (first && config.recordingMode == "always" && ac.runtime.cfg.recordCalls && !ac.recording) toggleRecord(ac)
            }
            dev.medut.CallState.HELD -> ac.phase = Phase.HELD
            dev.medut.CallState.ENDED, dev.medut.CallState.CANCELLED, dev.medut.CallState.FAILED -> {
                // Ended from this phone, the app or not (Telecom, a headset, a watch).
                if (e.endedLocally) ac.endedLocally = true
                finish(ac, e.state == dev.medut.CallState.FAILED, e.reason, e.state)
                return
            }
            else -> {}
        }
        push()
        pushState()
    }

    private fun finish(ac: ActiveCall, failed: Boolean, reason: String?, state: dev.medut.CallState) {
        ac.info = runCatching { ac.call.info() }.getOrNull() ?: ac.info // last chance for the final SIP status
        calls.remove(ac)
        ac.autoAnswer?.let(main::removeCallbacks)
        ac.backstop?.let(main::removeCallbacks)
        if (calls.none { it.phase == Phase.OUTGOING }) Ringback.stop()
        if (calls.isEmpty()) {
            routes = emptyList()
            route = "earpiece"
        }
        // Ended by the other side while recording: the SDK has already closed
        // the file but left its WAV header saying "no audio".
        if (ac.recording) {
            ac.recording = false
            Recordings.repairWav(ac.recordingPath)
        }
        for (c in calls) {
            if (c.transferOf === ac) c.transferOf = null
            if (c.replaces === ac) c.replaces = null
        }
        // The person we were consulting hung up, declined or never answered:
        // the caller waiting on hold comes back rather than being left there.
        val waiting = ac.transferOf
        if (waiting != null && calls.contains(waiting) && !waiting.transferring && waiting.phase == Phase.HELD) resume(waiting)
        if (focused === ac) focused = calls.firstOrNull()

        if (codeCall === ac) codeCall = null
        // A feature code waiting for the line, or the next one in a row.
        if (calls.isEmpty() && codeQueue.isNotEmpty()) main.postDelayed({ dialNextCode() }, 800)
        if (ac.featureCode) {
            push()
            pushState()
            return
        }

        val answered = ac.answeredAt > 0
        val result = if (ac.incoming) {
            // Unanswered and ended here (Decline in the app, on a headset or a
            // watch) was declined; ended by the caller or the network, missed.
            if (answered) "answered" else if (ac.userDeclined || ac.endedLocally) "declined" else "missed"
        } else {
            if (failed && !answered) "failed" else "answered"
        }
        val s = ac.stats
        val info = ac.info
        val now = System.currentTimeMillis()
        val sipCode = info?.sipStatus?.takeIf { it > 0 }
            ?: Regex("\\b([3-6]\\d\\d)\\b").find(reason ?: "")?.groupValues?.get(1)?.toIntOrNull()
        val cfg = ac.runtime.cfg
        val row = ContentValues().apply {
            put("account_id", cfg.id)
            put("account_name", cfg.label)
            put("number", ac.number)
            put("name", ac.name)
            put("direction", if (ac.incoming) "incoming" else "outgoing")
            put("result", result)
            put("started_at", ac.createdAt)
            if (answered) put("answered_at", ac.answeredAt)
            put("ended_at", now)
            put("duration", if (answered) ((now - ac.answeredAt) / 1000).toInt() else 0)
            if (s != null) {
                put("mos", (if (s.mosLqAvg > 0) s.mosLqAvg else s.mosLq).toDouble())
                if (s.mosLqMin > 0) put("mos_min", s.mosLqMin.toDouble())
                if (s.mosLqRx > 0) put("mos_rx", s.mosLqRx.toDouble())
                put("packets_lost", s.packetsLostRx)
                put("codec", s.codecName)
                put("ice", "${s.iceLocalType.name.lowercase(Locale.ROOT)} → ${s.iceRemoteType.name.lowercase(Locale.ROOT)}")
                put("remote_media", s.remoteAddress)
            } else {
                put("codec", "")
                put("ice", "")
                put("remote_media", "")
            }
            put("encryption", ac.crypto.ifEmpty { if (cfg.mediaEnc == "none") "none" else cfg.mediaEnc })
            put("call_id", info?.callId?.takeIf { it.isNotEmpty() } ?: ac.id)
            put("remote_uri", info?.peerUri ?: "")
            put("local_uri", info?.localUri ?: "")
            info?.setupDurationMs?.takeIf { it > 0 }?.let { put("setup_ms", it) }
            put("end_reason", reason?.takeIf { it.isNotEmpty() } ?: state.name.lowercase(Locale.ROOT))
            sipCode?.let { put("sip_code", it) }
            put("ended_by", if (ac.endedLocally || ac.userDeclined) "local" else "remote")
            if (ac.samples > 0) {
                put("rtt", ac.rttSum / ac.samples)
                put("jitter", ac.jitterSum / ac.samples)
                put("loss", ac.lossSum / ac.samples)
            }
            put("transport", cfg.transport.uppercase(Locale.ROOT))
            put("recording", ac.recordingPath)
            Recordings.wavSeconds(ac.recordingPath)?.let { put("rec_seconds", it) }
        }
        history.addCall(row)
        NativeBridge.toDart("historyChanged")
        if (result == "missed") notifyMissed(ac.title)
        if (failed && !reason.isNullOrEmpty() && foreground) notice(reason)
        push()
        pushState()
    }

    private fun notifyMissed(latest: String) {
        val count = history.missedSince(config.activitySeenAt)
        if (count <= 0) return
        CallNotifications.showMissed(
            app, count, latest,
            if (count > 1) config.label("missedCalls", "{n} missed calls", "n" to "$count")
            else config.label("missedCall", "Missed call"),
        )
    }

    /** Flutter showed the Calls tab: the missed-call notification goes away. */
    fun missedSeen() = CallNotifications.cancelMissed(app)

    // ── Actions from the call screen, notifications, Telecom and Flutter ───

    fun action(name: String, args: Map<String, Any?> = emptyMap()) {
        val ac = byId(args["callId"] as? String) ?: focused
        when (name) {
            "answer" -> ac?.let(::answer)
            "decline" -> ac?.let { decline(it, 603) }
            "busy" -> ac?.let { decline(it, 486) }
            "hangup" -> ac?.let(::hangup)
            "mute", "unmute" -> ac?.let { setMute(it, name == "mute") }
            "toggleMute" -> ac?.let { setMute(it, !it.muted) }
            "hold" -> ac?.let(::hold)
            "unhold" -> ac?.let(::resume)
            "route" -> {
                val id = args["routeId"] as? String
                if (id != null) selectRoute(id) else setRoute(args["route"] as? String ?: "earpiece")
            }
            "toggleSpeaker" -> toggleSpeaker()
            "record" -> ac?.let(::toggleRecord)
            "dtmf" -> (args["digit"] as? String)?.firstOrNull()?.let { d -> ac?.let { runCatching { it.call.sendDtmf(d) } } }
            "swap" -> swap()
            "answerWaiting" -> calls.firstOrNull { it.phase == Phase.INCOMING }?.let(::answer)
            "completeTransfer" -> completeTransfer()
            "cancelTransfer" -> cancelTransfer()
            "transferBlind" -> (args["target"] as? String)?.let(::transferBlind)
            "transferWarm" -> (args["target"] as? String)?.let(::transferAttended)
            "addCall" -> (args["number"] as? String)?.let { dial(it, focused?.runtime?.cfg?.id, null) }
            "reply", "message" -> ac?.let {
                if (name == "reply") decline(it, 486)
                MainActivity.open(app, "chat:${it.number}")
            }
        }
    }

    fun answer(ac: ActiveCall) {
        if (ac.phase != Phase.INCOMING) return
        for (other in calls.toList()) if (other !== ac && other.phase == Phase.ACTIVE) hold(other)
        focused = ac
        runCatching { ac.call.answer() }.onFailure { Log.w(TAG, "answer: $it") }
        push()
        pushState()
    }

    fun decline(ac: ActiveCall, code: Int = 603) {
        ac.userDeclined = true
        runCatching { ac.call.reject(code, if (code == 486) "Busy Here" else "Decline") }
    }

    fun hangup(ac: ActiveCall) {
        ac.endedLocally = true
        // Close the recording while the call still exists: once it has ended
        // the SDK has freed it.
        if (ac.recording) {
            runCatching { ac.call.stopRecording() }
            ac.recording = false
        }
        if (ac.phase == Phase.INCOMING) decline(ac) else runCatching { ac.call.hangup() }
    }

    private fun setMute(ac: ActiveCall, on: Boolean) {
        runCatching { ac.call.setMuted(on) }
        ac.muted = on
        push()
    }

    private fun hold(ac: ActiveCall) {
        if (ac.phase != Phase.ACTIVE) return
        runCatching { ac.call.hold() }
        ac.phase = Phase.HELD
        push()
        pushState()
    }

    private fun resume(ac: ActiveCall) {
        for (other in calls.toList()) if (other !== ac && other.phase == Phase.ACTIVE) hold(other)
        runCatching { ac.call.resume() }
        ac.phase = Phase.ACTIVE
        focused = ac
        push()
        pushState()
    }

    private fun swap() {
        calls.firstOrNull { it !== focused && it.phase != Phase.INCOMING }?.let(::resume)
    }

    private fun toggleRecord(ac: ActiveCall) {
        if (!ac.recording && config.recordingMode == "off") return
        if (ac.recording) {
            runCatching { ac.call.stopRecording() }
            ac.recording = false
        } else {
            val dir = Recordings.dir(app, config)
            dir.mkdirs()
            ac.recordingPath = java.io.File(dir, Recordings.name(ac.number, ac.name)).path
            ac.recording = runCatching { ac.call.startRecording(ac.recordingPath) }.isSuccess
        }
        push()
    }

    // ── Audio routes ───────────────────────────────────────────────────────

    private fun kindName(k: AudioRoute.Kind) = when (k) {
        AudioRoute.Kind.SPEAKER -> "speaker"
        AudioRoute.Kind.BLUETOOTH -> "bluetooth"
        AudioRoute.Kind.WIRED_HEADSET -> "wired"
        AudioRoute.Kind.EARPIECE -> "earpiece"
    }

    private fun applyRoutes(list: List<AudioRoute>) {
        routes = list
        list.firstOrNull { it.isActive }?.let { route = kindName(it.kind) }
    }

    private fun refreshRoutes() {
        runCatching { applyRoutes(MedutAndroid.audioRoutes.list()) }
        push()
    }

    /** A headset or speaker came or went (mute comes from onCallAudioStateChanged). */
    private fun onRoutesChanged() = refreshRoutes()

    /** When a call connects: a connected headset wins, otherwise the earpiece. */
    private fun initCallRoute() {
        refreshRoutes()
        val pick = Runnable {
            if (routes.isEmpty()) refreshRoutes()
            val headset = ofKind(AudioRoute.Kind.BLUETOOTH) ?: ofKind(AudioRoute.Kind.WIRED_HEADSET)
            if (headset != null && !headset.isActive) selectRoute(headset.id)
            else if (headset == null && route == "speaker") setRoute("earpiece")
        }
        if (routes.isEmpty()) main.postDelayed(pick, 400) else pick.run()
    }

    private fun ofKind(k: AudioRoute.Kind) = routes.firstOrNull { it.kind == k }

    /** Off the loudspeaker means back to the best headset: Bluetooth, wired, then the earpiece. */
    private fun preferredNonSpeaker() =
        ofKind(AudioRoute.Kind.BLUETOOTH) ?: ofKind(AudioRoute.Kind.WIRED_HEADSET) ?: ofKind(AudioRoute.Kind.EARPIECE)

    /** One-tap speaker button (call screen and the ongoing-call notification). */
    private fun toggleSpeaker() {
        val on = route == "speaker"
        val target = if (on) preferredNonSpeaker() else ofKind(AudioRoute.Kind.SPEAKER)
        if (target != null) return selectRoute(target.id)
        // No routes enumerated yet (call just connected): plain toggle.
        route = if (on) "earpiece" else "speaker"
        push()
        runCatching { MedutAndroid.audioRoutes.setSpeakerphone(!on) }
    }

    /**
     * Route call audio to an output picked on the call screen. The SDK goes
     * through Telecom while a Telecom call is up. The route asked for is shown
     * at once; the real one comes back through the route listener.
     */
    private fun selectRoute(id: String) {
        val r = routes.firstOrNull { it.id == id }
        if (r != null) route = kindName(r.kind)
        push()
        runCatching { routes = MedutAndroid.audioRoutes.select(id) }
        push()
    }

    private fun setRoute(kind: String) {
        val k = when (kind) {
            "speaker" -> AudioRoute.Kind.SPEAKER
            "bluetooth" -> AudioRoute.Kind.BLUETOOTH
            "wired" -> AudioRoute.Kind.WIRED_HEADSET
            else -> AudioRoute.Kind.EARPIECE
        }
        ofKind(k)?.let { return selectRoute(it.id) }
        if (k == AudioRoute.Kind.SPEAKER || k == AudioRoute.Kind.EARPIECE) {
            route = kind
            push()
            runCatching { MedutAndroid.audioRoutes.setSpeakerphone(k == AudioRoute.Kind.SPEAKER) }
        }
    }

    // ── Placing calls and transfers ────────────────────────────────────────

    /** Which account places a call to [number]: the one asked for, a dial rule, the default. */
    private fun accountFor(number: String, accountId: String?): AccountRuntime? {
        if (accountId != null) runtimes[accountId]?.takeIf { !it.probe }?.let { return it }
        for (r in config.dialRules) {
            if (r.matches(number)) runtimes[r.accountId]?.takeIf { !it.probe }?.let { return it }
        }
        val def = repo.defaultAccount() ?: return null
        return runtimes[def.id]
    }

    /** Places a call; an active call is put on hold first ("Add call"). */
    fun dial(input: String, accountId: String?, name: String?): ActiveCall? {
        val rt = accountFor(input, accountId)
        val acct = rt?.account
        if (rt == null || acct == null) {
            notice(config.label("noAccount", "Add a SIP account first"))
            return null
        }
        if (calls.size >= 2) {
            notice(config.label("twoCallsMax", "You can have two calls at once"))
            return null
        }
        for (other in calls.toList()) if (other.phase == Phase.ACTIVE) hold(other)
        return try {
            val call = acct.call(uriFor(rt.cfg, input))
            val number = userPart(input)
            val ac = ActiveCall(callIdOf(call), call, rt, false, number, name ?: nameFor(number), Phase.OUTGOING)
            calls.add(ac)
            focused = ac
            push()
            pushState()
            CallActivity.open(app)
            ac
        } catch (e: Exception) {
            notice("${config.label("callFailed", "Couldn't place the call")}: ${e.message}")
            null
        }
    }

    /**
     * Sends [ac]'s caller to [target] (REFER). The PBX ends our leg when it
     * takes the call; a refusal comes back as TransferFailed and the call
     * carries on. If neither happens, our leg is hung up after 20 s.
     */
    private fun refer(ac: ActiveCall, target: String) {
        ac.transferring = true
        runCatching { ac.call.transfer(referUri(ac.runtime.cfg, target)) }
            .onFailure { notice("${config.label("transferFailed", "Transfer failed")}: ${it.message}") }
        armBackstop(ac)
        push()
    }

    private fun armBackstop(ac: ActiveCall) {
        ac.backstop?.let(main::removeCallbacks)
        val r = Runnable { if (calls.contains(ac) && ac.transferring) hangup(ac) }
        ac.backstop = r
        main.postDelayed(r, 20_000)
    }

    /** Blind transfer: the caller goes straight to [target] and we leave. */
    fun transferBlind(target: String) {
        val ac = focused ?: return
        if (target.isBlank()) return
        refer(ac, target)
    }

    /** Warm transfer: hold the caller and call [target]; Join & drop joins them. */
    fun transferAttended(target: String) {
        val original = focused ?: return
        if (target.isBlank()) return
        dial(target, original.runtime.cfg.id, null)?.transferOf = original
        push()
    }

    /**
     * Joins the held caller to the person consulted (REFER with Replaces).
     * Still ringing there: the caller is sent to that number instead, since a
     * call nobody answered cannot be replaced.
     */
    private fun completeTransfer() {
        val consult = calls.firstOrNull { it.transferOf != null } ?: return
        val original = consult.transferOf ?: return
        if (consult.phase == Phase.OUTGOING || consult.phase == Phase.INCOMING) {
            consult.transferOf = null // its end must not take the caller off hold
            hangup(consult)
            refer(original, consult.number)
        } else {
            original.transferring = true
            runCatching { original.call.attendedTransfer(consult.call) }
                .onFailure { notice("${config.label("transferFailed", "Transfer failed")}: ${it.message}") }
            armBackstop(original)
            push()
        }
    }

    /** "Back to caller": ends the consult call; the caller comes off hold. */
    private fun cancelTransfer() {
        calls.firstOrNull { it.transferOf != null }?.let(::hangup)
    }

    private fun onTransferRequest(e: MedutEvent.TransferRequest) {
        // The other side (or the PBX) moves us to another party: follow it,
        // and drop the old leg once the new one answers. The transferor waits
        // for an answer either way, so one we cannot follow is refused.
        if (e.autoFollowed) return
        val c = e.call ?: return
        val old = find(c)
        val next = if (old == null) null else runCatching { c.acceptTransfer() }.getOrNull()
        if (next == null || old == null) {
            runCatching { c.rejectTransfer() }
            return
        }
        val number = userPart(e.referToUri)
        val ac = ActiveCall(callIdOf(next), next, old.runtime, false, number, nameFor(number), Phase.OUTGOING)
        ac.replaces = old
        calls.add(ac)
        focused = ac
        push()
        pushState()
    }

    private fun onTransferFailed(e: MedutEvent.TransferFailed) {
        val ac = e.call?.let(::find)
        if (ac != null) {
            ac.backstop?.let(main::removeCallbacks)
            val consult = calls.firstOrNull { it.transferOf === ac }
            if (consult != null && !ac.semiTried) {
                // The PBX would not join the two calls: send the caller to the
                // same person as a plain transfer instead.
                ac.semiTried = true
                consult.transferOf = null
                hangup(consult)
                refer(ac, consult.number)
                return
            }
            ac.transferring = false
            if (ac.phase == Phase.HELD) resume(ac)
            push()
        }
        val why = e.reason.orEmpty()
        notice(config.label("transferFailed", "Transfer failed") + if (why.isEmpty()) "" else ": $why")
    }

    fun sendMessage(peer: String, body: String, accountId: String?): String? {
        val rt = accountFor(peer, accountId)
        val acct = rt?.account ?: return config.label("noAccount", "Add a SIP account first")
        return try {
            acct.sendMessage(uriFor(rt.cfg, peer), body)
            history.addMessage(rt.cfg.id, userPart(peer), body, outgoing = true)
            NativeBridge.toDart("historyChanged")
            null
        } catch (e: Exception) {
            e.message ?: e.toString()
        }
    }

    // ── Names and numbers ──────────────────────────────────────────────────

    /** A Team name, else the phone's contact for [number] ('' when none). */
    fun nameFor(number: String): String {
        config.watched.firstOrNull { it.second == number }?.let { return it.first }
        names[number]?.let { return it }
        val found = try {
            val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
            app.contentResolver.query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) ?: "" else ""
            } ?: ""
        } catch (_: Exception) {
            "" // no contacts permission
        }
        if (names.size > 200) names.clear()
        names[number] = found
        return found
    }

    fun userPart(uri: String) = Numbers.userPart(uri)

    /** What was typed, as an AOR on [cfg]'s domain (SipService.uriFor). */
    fun uriFor(cfg: AccountCfg, input: String) =
        Numbers.uriFor(input, cfg.domain, cfg.port, cfg.plusReplace, cfg.dialPrefix)

    private fun referUri(cfg: AccountCfg, target: String) = Numbers.referUri(uriFor(cfg, target))

    private fun sameNumber(a: String, b: String) = Numbers.sameNumber(a, b)

    private fun notice(text: String) {
        if (mainActivityResumed) NativeBridge.toDart("notice", mapOf("text" to text))
        else Toast.makeText(app, text, Toast.LENGTH_LONG).show()
    }

    // ── Snapshot for the call screen, state for Flutter ────────────────────

    private fun push() {
        CallState.update(snapshot())
        // Screen off at the ear, whichever screen is showing: a live call on
        // the earpiece. Off for speaker, headsets, ringing and idle.
        setProximity(calls.any { it.phase != Phase.INCOMING } && route == "earpiece")
    }

    private fun setProximity(on: Boolean) {
        if (on) {
            if (proximity?.isHeld == true) return
            val pm = app.getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!pm.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) return
            proximity = pm.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "medut:proximity").apply {
                setReferenceCounted(false)
                acquire(4 * 60 * 60 * 1000L)
            }
        } else {
            proximity?.let { if (it.isHeld) it.release() }
            proximity = null
        }
    }

    private fun fmt(v: Float, d: Int = 0) = String.format(Locale.US, "%.${d}f", v)

    fun snapshot(): Map<String, Any?> {
        val base = mapOf<String, Any?>("dark" to config.dark, "rtl" to config.rtl)
        val f = focused ?: calls.firstOrNull() ?: return base + ("phase" to "idle")
        val other = calls.firstOrNull { it !== f }
        val s = if (config.showCallQuality) f.stats else null
        var level = if (s == null) 0 else Quality.level(
            s.mosLq.toDouble(), s.rttMs.toDouble(), s.jitterMs.toDouble(), s.lossPctRx.toDouble())
        if (f.link != "ok") level = 1
        val l = config
        val second: Map<String, Any?>? = other?.let {
            when {
                it.phase == Phase.INCOMING -> mapOf("name" to it.title,
                    "text" to "${CallNotifications.INCOMING} ${it.title}",
                    "label" to l.label("answer", "Answer"), "action" to "answerWaiting")
                f.transferOf === it -> mapOf("name" to it.title,
                    "text" to "${it.title} · ${l.label("onHold", "On hold")}",
                    "label" to l.label("complete", "Complete"), "action" to "completeTransfer")
                else -> mapOf("name" to it.title,
                    "text" to "${it.title} · ${l.label("onHold", "On hold")}",
                    "label" to l.label("swap", "Swap"), "action" to "swap")
            }
        }
        // A warm transfer under way: who is being consulted and whether they answered.
        val consult = calls.firstOrNull { it.transferOf != null && calls.contains(it.transferOf) }
        val transfer = consult?.let {
            val talking = it.phase == Phase.ACTIVE
            mapOf(
                "phase" to if (talking) "talking" else "calling",
                "status" to if (talking) l.label("xferConnectedTo", "Connected to {name}", "name" to it.title)
                else l.label("xferCalling", "Calling {name}…", "name" to it.title),
                "hint" to if (talking) l.label("xferHintTalking", "Join & drop connects them and you leave the call.")
                else l.label("xferHintCalling", "Your caller is on hold and can't hear this."),
                "join" to l.label("xferJoin", "Join & drop"),
                "back" to l.label("xferBack", "Back to caller"),
            )
        }
        val status = if (f.transferring) l.label("transferring", "Transferring…") else when (f.phase) {
            Phase.OUTGOING -> if (f.remoteRinging) l.label("ringing", "Ringing") else l.label("calling", "Calling…")
            Phase.HELD -> l.label("onHold", "On hold")
            else -> when (f.link) {
                "reconnecting" -> l.label("reconnecting", "Reconnecting…")
                "weak" -> l.label("poorConnection", "Poor connection")
                // Shown while recording, so it is never silent that a call is recorded.
                else -> if (f.recording) l.label("recordingNow", "This call is being recorded") else ""
            }
        }
        val cfg = f.runtime.cfg
        return base + mapOf(
            "transfer" to transfer,
            "phase" to f.phase.wire,
            "ring" to (f.phase == Phase.INCOMING && f.ringShown),
            "callId" to f.id,
            "name" to f.name,
            "number" to f.number,
            "account" to "${cfg.label} · ${cfg.user}",
            "accountId" to cfg.id,
            "status" to status,
            "link" to f.link,
            "canRecord" to (config.recordingMode != "off" || f.recording),
            "startedAt" to f.answeredAt,
            "outgoing" to !f.incoming,
            "muted" to f.muted,
            "held" to (f.phase == Phase.HELD),
            "route" to route,
            // A picker is only worth showing when a headset is there to choose.
            "bluetooth" to routes.any { it.kind == AudioRoute.Kind.BLUETOOTH || it.kind == AudioRoute.Kind.WIRED_HEADSET },
            "routes" to routes.map {
                mapOf("id" to it.id, "kind" to kindName(it.kind),
                    "name" to it.name.ifEmpty { l.label(kindName(it.kind).let { k -> if (k == "wired") "headset" else k }, kindName(it.kind)) })
            },
            "ringtone" to config.ringtone,
            "vibrate" to config.vibrate,
            "recording" to f.recording,
            "mos" to if (s == null) "" else fmt(s.mosLq, 1),
            "mosYou" to if (s == null || s.mosLq <= 0) "" else fmt(s.mosLq, 1),
            "mosThem" to if (s == null || s.mosLqRx <= 0) "" else fmt(s.mosLqRx, 1),
            "encrypted" to f.crypto.isNotEmpty(),
            // 3-bar grade. "Checking…" until the first sample; a link in trouble is never better than poor.
            "qualityLevel" to level,
            "qualityWord" to if (config.showCallQuality && f.phase == Phase.ACTIVE)
                l.label(Quality.wordKey(level), Quality.wordFallback(level)) else "",
            "quality" to when {
                level >= 3 -> "good"
                level == 2 -> "fair"
                level == 1 -> "poor"
                else -> ""
            },
            "details" to if (s == null) emptyList() else listOf(
                listOf(l.label("qJitter", "Jitter"), "${fmt(s.jitterMs)} ms"),
                listOf(l.label("qLoss", "Packet loss"), "${fmt(s.lossPct, 1)} %"),
                listOf(l.label("qRtt", "Round trip"), "${fmt(s.rttMs)} ms"),
                listOf(l.label("qCodec", "Codec"), "${s.codecName} ${s.codecClockRate / 1000} kHz"),
                listOf(l.label("qSrtp", "Encryption"), f.crypto.ifEmpty { l.label("encNone", "None") }),
                listOf(l.label("qIce", "Network path"), s.iceLocalType.name.lowercase(Locale.ROOT)),
                listOf(l.label("qJbuf", "Jitter buffer"), "${s.jitterBufferMs} ms"),
                listOf(l.label("connection", "Connection"), "${cfg.transport.uppercase(Locale.ROOT)} · ${cfg.domain}"),
            ),
            "second" to second,
        )
    }

    private var statePosted = false

    /** Sends Flutter what its tabs show, once per main-loop turn at most. */
    fun pushState() {
        if (statePosted) return
        statePosted = true
        main.post {
            statePosted = false
            NativeBridge.toDart("state", state())
        }
    }

    fun state(): Map<String, Any?> = mapOf(
        "accounts" to runtimes.mapValues { (_, rt) ->
            mapOf(
                "status" to rt.status, "error" to rt.error, "sipCode" to rt.sipCode, "retryInMs" to rt.retryInMs,
                "mwiNew" to rt.mwiNew, "mwiOld" to rt.mwiOld, "mwiUrgent" to rt.mwiUrgent, "probe" to rt.probe,
            )
        },
        "calls" to calls.map {
            mapOf("id" to it.id, "accountId" to it.runtime.cfg.id, "number" to it.number, "name" to it.name,
                "phase" to it.phase.wire, "answeredAt" to it.answeredAt)
        },
        "focused" to focused?.id,
        "presence" to HashMap(presence),
        "version" to if (sdkUp) runCatching { Medut.version }.getOrDefault("") else "",
        "connSeq" to EngineLog.seq("conn"),
        "sipSeq" to EngineLog.seq("sip"),
    )
}
