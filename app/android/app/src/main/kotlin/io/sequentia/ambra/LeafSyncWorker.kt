package io.sequentia.ambra

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The scheduled pass while the app is closed: starts a Flutter engine with no UI and
 * runs the Dart entry point `leafSyncJob` (lib/main.dart), which opens the leaf wallet
 * from the app's own storage, syncs it, and reports back over the `ambra/leaf_job`
 * channel: a notification per coin received, and when to run next.
 */
class LeafSyncWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val main = Handler(Looper.getMainLooper())
        val done = CountDownLatch(1)
        var next: Long? = null
        var finished = false
        var engine: FlutterEngine? = null
        main.post {
            try {
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(applicationContext)
                loader.ensureInitializationComplete(applicationContext, null)
                val e = FlutterEngine(applicationContext)
                engine = e
                MethodChannel(e.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
                    when (call.method) {
                        "notify" -> {
                            LeafJobs.notifyArrived(
                                applicationContext,
                                call.argument<String>("id") ?: "",
                                call.argument<String>("title") ?: "Ambra",
                                call.argument<String>("body") ?: "",
                            )
                            result.success(null)
                        }
                        "done" -> {
                            // wake_in in seconds, or null: nothing waits.
                            next = (call.argument<Number>("wake_in"))?.toLong()
                            finished = call.argument<Boolean>("ok") ?: false
                            Log.i(TAG, "pass done: ok=$finished wake_in=$next (${call.argument<String>("summary") ?: ""})")
                            result.success(null)
                            done.countDown()
                        }
                        else -> result.notImplemented()
                    }
                }
                e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "leafSyncJob"))
            } catch (t: Throwable) {
                Log.e(TAG, "the pass did not start", t)
                done.countDown()
            }
        }
        val answered = done.await(9, TimeUnit.MINUTES)
        main.post { engine?.destroy() }
        val n = next
        when {
            !answered || !finished -> {
                // No answer, or the pass failed (no network, operator down): try again
                // in an hour, still within the daily rule.
                LeafJobs.schedule(applicationContext, RETRY, fromJob = true)
            }
            n != null -> LeafJobs.schedule(applicationContext, n, fromJob = true)
            else -> Log.i(TAG, "nothing waits: no further pass planned")
        }
        return Result.success()
    }

    companion object {
        const val CHANNEL = "ambra/leaf_job"
        private const val TAG = "AmbraLeafJob"
        private const val RETRY = 3_600L
    }
}
