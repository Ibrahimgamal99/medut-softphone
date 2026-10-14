package com.medut.generic.phone.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * After a reboot or an app update, bring the keep-alive service back. The
 * process start has already started the engine (MedutApp), which registers
 * the accounts; this only keeps the process from being reclaimed afterwards.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (MedutService.keepAliveEnabled(context)) MedutService.sync(context)
    }
}
