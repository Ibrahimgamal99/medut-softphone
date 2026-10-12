package com.medut.generic.phone.telecom

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telecom.CallAudioState
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log
import com.medut.generic.phone.CallSnapshot

/**
 * Self-managed Telecom integration. A live call is a real Telecom call, so
 * Android grants the microphone while the app is in the background or the
 * screen is locked, routes Bluetooth, and holds our call when a cellular call
 * comes in. Our own screens stay in charge of the UI.
 */
object MedutTelecom {
    private const val TAG = "MedutTelecom"
    private const val ACCOUNT_ID = "medut_self_managed"
    const val EXTRA_NAME = "medut_name"
    const val EXTRA_NUMBER = "medut_number"

    private val main = Handler(Looper.getMainLooper())

    @Volatile
    var connection: MedutConnection? = null
        private set

    private fun handle(context: Context) = PhoneAccountHandle(
        ComponentName(context.applicationContext, MedutConnectionService::class.java),
        ACCOUNT_ID,
    )

    fun registerPhoneAccount(context: Context) {
        try {
            val tm = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val account = PhoneAccount.builder(handle(context), "Medut")
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .setSupportedUriSchemes(listOf(PhoneAccount.SCHEME_SIP, PhoneAccount.SCHEME_TEL))
                .build()
            tm.registerPhoneAccount(account)
        } catch (e: Exception) {
            Log.e(TAG, "registerPhoneAccount failed", e)
        }
    }

    private fun extras(s: CallSnapshot) = Bundle().apply {
        putString(EXTRA_NAME, s.name)
        putString(EXTRA_NUMBER, s.number)
    }

    private fun address(s: CallSnapshot): Uri =
        Uri.fromParts(PhoneAccount.SCHEME_SIP, s.number.ifBlank { "unknown" }, null)

    /** Returns false when Telecom refused, so the caller can ring on its own. */
    fun startIncoming(context: Context, s: CallSnapshot): Boolean {
        connection?.let { c ->
            main.post { c.updateCaller(s.name, s.number) }
            return true
        }
        return try {
            val tm = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            tm.addNewIncomingCall(handle(context), Bundle().apply {
                putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, address(s))
                putBundle(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS, extras(s))
            })
            true
        } catch (e: Exception) {
            Log.e(TAG, "addNewIncomingCall failed", e)
            false
        }
    }

    fun startOutgoing(context: Context, s: CallSnapshot) {
        if (connection != null) return
        try {
            val tm = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            tm.placeCall(address(s), Bundle().apply {
                putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle(context))
                putBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS, extras(s))
            })
        } catch (e: Exception) {
            // Not fatal: the call works, it just isn't known to Telecom.
            Log.e(TAG, "placeCall failed", e)
        }
    }

    fun setActive() = main.post { connection?.setActive() }

    fun setHeld(held: Boolean) = main.post {
        val c = connection ?: return@post
        if (held) c.setOnHold() else c.setActive()
    }

    @Suppress("DEPRECATION")
    fun setRoute(route: String) = main.post {
        val c = connection ?: return@post
        val r = when (route) {
            "speaker" -> CallAudioState.ROUTE_SPEAKER
            "bluetooth" -> CallAudioState.ROUTE_BLUETOOTH
            "wired" -> CallAudioState.ROUTE_WIRED_HEADSET
            else -> CallAudioState.ROUTE_WIRED_OR_EARPIECE
        }
        try {
            c.setAudioRoute(r)
        } catch (e: Exception) {
            Log.e(TAG, "setAudioRoute failed", e)
        }
    }

    fun end() = main.post {
        val c = connection ?: return@post
        connection = null
        try {
            c.setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
            c.destroy()
        } catch (e: Exception) {
            Log.e(TAG, "end failed", e)
        }
    }

    internal fun onCreated(c: MedutConnection) {
        connection = c
    }

    internal fun onGone(c: MedutConnection) {
        if (connection === c) connection = null
    }
}
