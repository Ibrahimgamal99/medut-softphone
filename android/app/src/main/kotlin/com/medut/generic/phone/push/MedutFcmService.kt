package com.medut.generic.phone.push

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.medut.generic.phone.engine.EngineLog
import com.medut.generic.phone.engine.PhoneEngine
import dev.medut.Medut
import dev.medut.android.MedutPush
import dev.medut.android.PushPayload

/**
 * FCM wake-up. The process start has already started the engine (MedutApp)
 * and re-created the accounts. A call push rings at once (the engine's
 * onPushRing) while the accounts refresh their registration, so an RFC 8599
 * server releases the INVITE, which takes the ring over. Needs
 * android/app/google-services.json.
 */
class MedutFcmService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        if (!PhoneEngine.sdkUp) return
        val payload = withAccountAor(PushPayload.parse(message.data))
        val line = "push ${payload.type.name.lowercase()}: call_id=${payload.callId ?: "-"} aor=${payload.aor ?: "-"} " +
            "caller=${payload.callerUri ?: "-"}"
        Log.i(TAG, line)
        EngineLog.conn(line)
        // The wait for the INVITE gets its own thread (the SDK holds a wake
        // lock for it): FCM hands over one push at a time, so blocking here
        // would hold a cancel push back until the call push's wait is over.
        val context = applicationContext
        Thread({
            val call = runCatching { MedutPush.wake(context, payload, PhoneEngine.PUSH_WAIT_MS) }.getOrNull()
            // A cancel push, or no INVITE in time: the SDK has ended the ring.
            if (call == null && payload.type != PushPayload.Type.OTHER) main.post { PhoneEngine.pushRingOver(payload) }
        }, "medut-push").start()
    }

    /**
     * The push's AOR as the account registered it. A server often names the
     * account by its own address (sip:1000@203.0.113.5 for sip:1000@pbx.example.com),
     * and the SDK binds the INVITE to the ring only on an exact AOR: anything
     * else rings twice and the INVITE gets a 486. The same user on exactly one
     * account is that account.
     */
    private fun withAccountAor(p: PushPayload): PushPayload {
        val aor = p.aor ?: return p
        val accounts = runCatching { Medut.accounts.map { it.aor } }.getOrDefault(emptyList())
        if (accounts.any { bare(it) == bare(aor) }) return p
        val user = bare(aor).substringBefore('@')
        val same = accounts.filter { bare(it).substringBefore('@') == user }
        if (same.size != 1) return p
        EngineLog.conn("push aor $aor is account ${same[0]}")
        return p.copy(aor = same[0])
    }

    private fun bare(uri: String) = uri.trim().lowercase().removePrefix("sips:").removePrefix("sip:")
        .substringBefore(';').substringBefore('>')

    override fun onNewToken(token: String) {
        main.post { PhoneEngine.setPushToken(token) }
    }

    private companion object {
        const val TAG = "MedutFcm"
        val main = Handler(Looper.getMainLooper())
    }
}
