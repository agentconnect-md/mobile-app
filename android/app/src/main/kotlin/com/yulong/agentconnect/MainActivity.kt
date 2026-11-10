package com.yulong.agentconnect

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.browser.customtabs.CustomTabsIntent
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Same "agentconnect/native" channel as iOS: build environment, the sign-in page
 * (Custom Tabs), the custom-scheme callback and console session links. Never logs
 * URLs: they carry the authorization code. FlutterFragmentActivity because
 * local_auth needs it.
 */
class MainActivity : FlutterFragmentActivity() {
    private var channel: MethodChannel? = null
    private var pending: MethodChannel.Result? = null
    private var leftForBrowser = false

    /** The console link the app was launched with: kept until Dart asks for it. */
    private var initialLink: String? = null
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "agentconnect/native")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "env" -> result.success(
                    mapOf(
                        "name" to getString(R.string.ac_env_name),
                        "apiBase" to getString(R.string.ac_api_base),
                        "callbackHost" to getString(R.string.ac_callback_host),
                        "callbackPath" to getString(R.string.ac_callback_path),
                        "urlScheme" to getString(R.string.ac_url_scheme),
                    )
                )
                "authenticate" -> {
                    val url = call.argument<String>("url")
                    if (url == null) {
                        result.error("FAILED", null, null)
                    } else {
                        authenticate(Uri.parse(url), result)
                    }
                }
                "cancel" -> {
                    finish(null, "CANCELED")
                    result.success(null)
                }
                "initialLink" -> {
                    result.success(initialLink)
                    initialLink = null
                }
                "debugTab" -> result.success(intent?.getStringExtra("acDebugTab"))
                "debugOpen" -> result.success(intent?.getStringExtra("acDebugOpen"))
                else -> result.notImplemented()
            }
        }
        initialLink = consoleLink(intent)
        if (initialLink != null) intent.data = null
        handleCallback(intent)
    }

    private fun authenticate(url: Uri, result: MethodChannel.Result) {
        if (pending != null) finish(null, "CANCELED")
        pending = result
        try {
            CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(this, url)
            leftForBrowser = true
        } catch (e: ActivityNotFoundException) {
            try {
                startActivity(Intent(Intent.ACTION_VIEW, url))
                leftForBrowser = true
            } catch (e2: ActivityNotFoundException) {
                finish(null, "FAILED")
            }
        }
    }

    private fun finish(url: String?, error: String?) {
        val r = pending ?: return
        pending = null
        leftForBrowser = false
        if (url != null) r.success(url) else r.error(error ?: "FAILED", null, null)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val link = consoleLink(intent)
        if (link != null) {
            intent.data = null
            channel?.invokeMethod("link", link)
            return
        }
        handleCallback(intent)
    }

    /**
     * A console session page (`https://<console>/<org>/sessions/<id>…`) opened as an
     * app link. Other console pages are left alone; Dart parses the rest.
     */
    private fun consoleLink(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val data = intent.data ?: return null
        if (!data.scheme.equals("https", ignoreCase = true)) return null
        if (!data.host.equals(getString(R.string.ac_callback_host), ignoreCase = true)) return null
        val segs = data.pathSegments
        if (segs.size != 3 || segs[1] != "sessions") return null
        return data.toString()
    }

    /** `<scheme>://oauth/callback?...`: hand it to the waiting sign-in (state is checked in Dart). */
    private fun handleCallback(intent: Intent?) {
        val data = intent?.data ?: return
        val scheme = getString(R.string.ac_url_scheme)
        if (!data.scheme.equals(scheme, ignoreCase = true)) return
        intent.data = null
        if (data.host == "oauth" && data.path == "/callback") {
            if (pending != null) finish(data.toString(), null)
            else channel?.invokeMethod("staleCallback", null)
        } else {
            channel?.invokeMethod("link", data.toString())
        }
    }

    override fun onResume() {
        super.onResume()
        // Back from the browser without a callback: the user closed the page.
        if (leftForBrowser && pending != null) {
            main.postDelayed({ if (pending != null && leftForBrowser) finish(null, "CANCELED") }, 800)
        }
    }
}
