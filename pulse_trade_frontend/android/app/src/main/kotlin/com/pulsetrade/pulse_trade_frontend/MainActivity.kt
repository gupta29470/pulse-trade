package com.pulsetrade.pulse_trade_frontend

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter UI and forwards `pulsetrade://` links to it.
 *
 * Android delivers a deep link as an intent, and nothing in Flutter reads one on
 * its own, so this is the half that hands the URI across. A link that started
 * the process is held until Dart asks for it, because the activity is configured
 * before the Dart isolate exists; a link that arrives while the app runs is
 * pushed straight through.
 */
class MainActivity : FlutterActivity() {

    private val channelName = "pulsetrade/deeplink"
    private var channel: MethodChannel? = null
    private var pending: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        // Read once, then cleared: a cold-start link must not be
                        // replayed on every reconnect or rebuild.
                        "initial" -> {
                            result.success(pending)
                            pending = null
                        }
                        else -> result.notImplemented()
                    }
                }
            }
        pending = intent?.data?.toString() ?: pending
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val uri = intent.data?.toString() ?: return
        val active = channel
        if (active == null) {
            pending = uri
        } else {
            active.invokeMethod("open", uri)
        }
    }
}
