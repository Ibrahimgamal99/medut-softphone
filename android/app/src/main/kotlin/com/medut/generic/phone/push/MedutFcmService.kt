package com.medut.generic.phone.push

import android.os.Handler
import android.os.Looper
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.medut.generic.phone.engine.PhoneEngine
import dev.medut.android.MedutPush

/**
 * FCM wake-up. The process start has already started the engine (MedutApp)
 * and re-created the accounts; the push makes them refresh their
 * registration so an RFC 8599 server releases the INVITE, which then rings
 * like any other call. Needs android/app/google-services.json.
 */
class MedutFcmService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        if (!PhoneEngine.sdkUp) return
        // Blocks this (FCM's own) thread until the INVITE is in, or 20 s.
        runCatching { MedutPush.wake(this, message.data, 20_000) }
    }

    override fun onNewToken(token: String) {
        Handler(Looper.getMainLooper()).post { PhoneEngine.setPushToken(token) }
    }
}
