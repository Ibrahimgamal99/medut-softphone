package com.medut.generic.phone.telecom

import android.net.Uri
import android.os.Bundle
import android.telecom.CallAudioState
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log
import com.medut.generic.phone.CallState
import com.medut.generic.phone.NativeBridge
import com.medut.generic.phone.call.CallNotifications

class MedutConnectionService : ConnectionService() {

    override fun onCreateIncomingConnection(
        account: PhoneAccountHandle?,
        request: ConnectionRequest,
    ): Connection {
        val inner = request.extras?.getBundle(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS)
            ?: request.extras
        return MedutConnection(this).apply {
            updateCaller(
                inner?.getString(MedutTelecom.EXTRA_NAME) ?: "",
                inner?.getString(MedutTelecom.EXTRA_NUMBER) ?: "",
            )
            setRinging()
            MedutTelecom.onCreated(this)
        }
    }

    override fun onCreateOutgoingConnection(
        account: PhoneAccountHandle?,
        request: ConnectionRequest,
    ): Connection {
        val extras: Bundle? = request.extras?.getBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS)
            ?: request.extras
        return MedutConnection(this).apply {
            updateCaller(
                extras?.getString(MedutTelecom.EXTRA_NAME) ?: "",
                extras?.getString(MedutTelecom.EXTRA_NUMBER) ?: "",
            )
            setDialing()
            MedutTelecom.onCreated(this)
            // Dart may already report the call connected by the time Telecom binds.
            if (CallState.latest.phase == "active") setActive()
        }
    }

    override fun onCreateIncomingConnectionFailed(account: PhoneAccountHandle?, request: ConnectionRequest?) {
        Log.w(TAG, "incoming connection refused by Telecom — ringing without it")
        CallNotifications.showIncoming(this, CallState.latest)
    }

    override fun onCreateOutgoingConnectionFailed(account: PhoneAccountHandle?, request: ConnectionRequest?) {
        Log.w(TAG, "outgoing connection refused by Telecom")
    }

    companion object {
        private const val TAG = "MedutConnService"
    }
}

class MedutConnection(private val service: ConnectionService) : Connection() {

    init {
        setAudioModeIsVoip(true)
        connectionProperties = PROPERTY_SELF_MANAGED
        connectionCapabilities = CAPABILITY_HOLD or CAPABILITY_SUPPORT_HOLD or CAPABILITY_MUTE
    }

    private var lastMute: Boolean? = null

    fun updateCaller(name: String, number: String) {
        val display = name.ifBlank { number }
        if (display.isNotBlank()) setCallerDisplayName(display, TelecomManager.PRESENTATION_ALLOWED)
        if (number.isNotBlank()) {
            setAddress(Uri.fromParts(PhoneAccount.SCHEME_SIP, number, null), TelecomManager.PRESENTATION_ALLOWED)
        }
    }

    // The system UI is never shown for a self-managed call: we post our own
    // full-screen ring notification here.
    override fun onShowIncomingCallUi() {
        CallNotifications.showIncoming(service, CallState.latest)
    }

    // Answer / reject / hang up from a headset, a watch or the car.
    override fun onAnswer() = NativeBridge.action("answer")

    override fun onReject() {
        setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
        destroy()
        MedutTelecom.onGone(this)
        NativeBridge.action("decline")
    }

    override fun onDisconnect() {
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        destroy()
        MedutTelecom.onGone(this)
        NativeBridge.action("hangup")
    }

    override fun onAbort() = onDisconnect()

    // A cellular call coming in holds ours, and resumes it after.
    override fun onHold() {
        setOnHold()
        NativeBridge.action("hold")
    }

    override fun onUnhold() {
        setActive()
        NativeBridge.action("unhold")
    }

    @Deprecated("Deprecated in Java")
    override fun onCallAudioStateChanged(state: CallAudioState) {
        val route = when (state.route) {
            CallAudioState.ROUTE_SPEAKER -> "speaker"
            CallAudioState.ROUTE_BLUETOOTH -> "bluetooth"
            CallAudioState.ROUTE_WIRED_HEADSET -> "wired"
            else -> "earpiece"
        }
        val bt = state.supportedRouteMask and CallAudioState.ROUTE_BLUETOOTH != 0
        NativeBridge.toDart("audioRoute", mapOf("route" to route, "bluetooth" to bt))
        if (lastMute != state.isMuted) {
            val first = lastMute == null
            lastMute = state.isMuted
            if (!first) NativeBridge.action(if (state.isMuted) "mute" else "unmute")
        }
    }
}
