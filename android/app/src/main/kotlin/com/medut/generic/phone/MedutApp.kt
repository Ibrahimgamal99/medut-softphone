package com.medut.generic.phone

import android.app.Application
import com.medut.generic.phone.engine.PhoneEngine

/**
 * Starts the phone on every process start (launcher, boot, FCM wake-up):
 * [PhoneEngine] registers the accounts and rings calls with no Flutter engine
 * up. Flutter only starts when the app's screens are opened.
 * [com.medut.generic.phone.service.MedutService] keeps the process alive in
 * the background.
 */
class MedutApp : Application() {
    override fun onCreate() {
        super.onCreate()
        PhoneEngine.start(this)
    }
}
