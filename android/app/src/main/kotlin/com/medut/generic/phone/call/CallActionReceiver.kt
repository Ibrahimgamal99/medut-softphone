package com.medut.generic.phone.call

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.medut.generic.phone.NativeBridge

/** Decline / Hang up from a notification, without bringing any screen up. */
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            DECLINE -> {
                Ringer.stop()
                CallNotifications.cancelIncoming(context)
                NativeBridge.action("decline")
            }
            HANGUP -> NativeBridge.action("hangup")
            TOGGLE_MUTE -> NativeBridge.action("toggleMute")
            TOGGLE_SPEAKER -> NativeBridge.action("toggleSpeaker")
        }
    }

    companion object {
        const val DECLINE = "com.medut.generic.phone.DECLINE"
        const val HANGUP = "com.medut.generic.phone.HANGUP"
        const val TOGGLE_MUTE = "com.medut.generic.phone.TOGGLE_MUTE"
        const val TOGGLE_SPEAKER = "com.medut.generic.phone.TOGGLE_SPEAKER"
    }
}
