package io.sequentia.ambra

import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.view.WindowManager

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth: its
// BiometricPrompt can only be hosted by a FragmentActivity. With a plain
// FlutterActivity, authenticate() throws `no_fragment_activity`, which made the
// app-lock and payment-auth prompts unable to appear.
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    // FLAG_SECURE, app-wide. The wallet renders the recovery phrase (onboarding
    // create/verify + the "Reveal recovery phrase" sheet), balances, and receive
    // addresses. Marking the window secure keeps EVERY screen out of screenshots
    // and the OS "recents" thumbnail, so a seed screen that was on top when the
    // app was backgrounded cannot leak into the task switcher. App-wide (rather
    // than per-route) is deliberate: it has no route-tracking gap a sensitive
    // sheet could slip through.
    //
    // A debuggable build started with the extra `ambra.screenshots=true` leaves
    // the window capturable, for screenshots of a test run. A release build is
    // never debuggable, so it always sets the flag.
    // TODO(device-verify): confirm on a real device/emulator that seed screens no
    // longer appear in a screenshot or the recents thumbnail (cannot be built here).
    override fun onCreate(savedInstanceState: Bundle?) {
        val debuggable = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val capturable = debuggable && intent?.getBooleanExtra("ambra.screenshots", false) == true
        if (!capturable) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The leaf wallet's Android side: the foreground service while the app runs,
        // the scheduled pass while it does not, and the notification of a coin received.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ambra/leaves").setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> { LeafSyncService.start(this); result.success(null) }
                "stopService" -> { LeafSyncService.stop(this); result.success(null) }
                "schedule" -> {
                    LeafJobs.schedule(this, (call.argument<Number>("seconds") ?: 0).toLong())
                    result.success(null)
                }
                "cancel" -> { LeafJobs.cancel(this); result.success(null) }
                "notify" -> {
                    LeafJobs.notifyArrived(
                        this,
                        call.argument<String>("id") ?: "",
                        call.argument<String>("title") ?: "Ambra",
                        call.argument<String>("body") ?: "",
                    )
                    result.success(null)
                }
                "share" -> {
                    val send = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(android.content.Intent.EXTRA_TEXT, call.argument<String>("text") ?: "")
                    }
                    startActivity(android.content.Intent.createChooser(send, "Share the request"))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
