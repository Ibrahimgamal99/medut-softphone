package com.medut.generic.phone

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Shows the Flutter UI on the engine [MedutApp] already started. The engine is
 * not destroyed with the activity: closing the app must not drop the SIP
 * registration or a live call.
 */
class MainActivity : FlutterActivity() {

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        (application as MedutApp).ensureEngine()

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleRoute(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleRoute(intent)
    }

    /** The native call screen opens the app on a Flutter flow (transfer, chat...). */
    private fun handleRoute(intent: Intent?) {
        val route = intent?.getStringExtra(EXTRA_ROUTE) ?: return
        intent.removeExtra(EXTRA_ROUTE)
        NativeBridge.toDart("openRoute", mapOf("route" to route))
    }

    companion object {
        const val EXTRA_ROUTE = "medut_route"

        fun open(context: Context, route: String? = null) {
            val i = Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            if (route != null) i.putExtra(EXTRA_ROUTE, route)
            context.startActivity(i)
        }
    }
}
