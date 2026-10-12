package com.medut.generic.phone

import android.app.Application
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import com.medut.generic.phone.call.CallNotifications
import com.medut.generic.phone.telecom.MedutTelecom

/**
 * Owns the one Flutter engine of the process.
 *
 * The SIP stack is driven from Dart, so it lives exactly as long as this
 * engine. Starting the engine here — not in MainActivity — means it runs on
 * every process start (launcher, boot, FCM wake-up) and survives the activity
 * being closed or swiped away. [com.medut.generic.phone.service.MedutService]
 * keeps the process itself alive in the background.
 */
class MedutApp : Application() {

    override fun onCreate() {
        super.onCreate()
        instance = this
        CallNotifications.createChannels(this)
        MedutTelecom.registerPhoneAccount(this)
        CallState.init(this)
        ensureEngine()
    }

    fun ensureEngine(): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(this)
        loader.ensureInitializationComplete(this, null)
        val engine = FlutterEngine(this)
        NativeBridge.attach(this, engine.dartExecutor.binaryMessenger)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    companion object {
        const val ENGINE_ID = "medut_main"

        lateinit var instance: MedutApp
            private set
    }
}
