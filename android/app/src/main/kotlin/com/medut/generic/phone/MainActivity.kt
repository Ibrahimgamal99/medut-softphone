package com.medut.generic.phone

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * The Flutter screens: history, accounts, contacts, settings. The engine is
 * made on first open and kept, so coming back from the call screen is
 * instant; calls themselves never need it.
 */
class MainActivity : FlutterActivity() {

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val engine = FlutterEngine(context.applicationContext)
        // The channel is up before Dart runs: main() asks for the accounts first thing.
        NativeBridge.attach(context, engine.dartExecutor.binaryMessenger)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleRoute(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleRoute(intent)
    }

    /** A notification or the call screen opens the app on a flow (chat, Calls tab). */
    private fun handleRoute(intent: Intent?) {
        val route = intent?.getStringExtra(EXTRA_ROUTE) ?: return
        intent.removeExtra(EXTRA_ROUTE)
        NativeBridge.toDart("openRoute", mapOf("route" to route))
    }

    companion object {
        const val EXTRA_ROUTE = "medut_route"
        private const val ENGINE_ID = "medut_ui"

        fun open(context: Context, route: String? = null) {
            val i = Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            if (route != null) i.putExtra(EXTRA_ROUTE, route)
            context.startActivity(i)
        }
    }
}
