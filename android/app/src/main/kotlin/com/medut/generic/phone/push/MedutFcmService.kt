package com.medut.generic.phone.push

import android.os.Handler
import android.os.Looper
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.medut.generic.phone.engine.PhoneEngine
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
        val payload = PushPayload.parse(message.data)
        // Blocks this (FCM's own) thread until the INVITE is in, or the wait is over.
        val call = runCatching { MedutPush.wake(this, payload, PhoneEngine.PUSH_WAIT_MS) }.getOrNull()
        // A cancel push, or no INVITE in time: the SDK has ended the ring.
        if (call == null && payload.type != PushPayload.Type.OTHER) main.post { PhoneEngine.pushRingOver(payload) }
    }

    override fun onNewToken(token: String) {
        main.post { PhoneEngine.setPushToken(token) }
    }

    private companion object {
        val main = Handler(Looper.getMainLooper())
    }
}
