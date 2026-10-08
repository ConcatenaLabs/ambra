package io.sequentia.ambra

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

/**
 * The leaf wallet's schedule and notifications on Android.
 *
 * While the app is closed, one job ([LeafSyncWorker]) syncs the leaf wallet: it runs
 * at the time the wallet library's schedule names (`next_sync_at`), and never more
 * than a day apart while a coin is off the chain or a receive request is open. Each
 * pass names the next one. A coin the pass reads from the mailbox raises a
 * notification.
 */
object LeafJobs {
    const val WORK = "ambra-leaf-sync"
    const val CHANNEL_ARRIVED = "ambra-leaves-arrived"
    const val CHANNEL_SERVICE = "ambra-leaves-service"
    private const val DAY = 86_400L

    /**
     * The next pass in [seconds]. [fromJob] when the running pass names it: the new
     * pass then follows this one rather than replacing it, which would cancel it.
     */
    fun schedule(context: Context, seconds: Long, fromJob: Boolean = false) {
        val delay = seconds.coerceIn(0L, DAY)
        val request = OneTimeWorkRequestBuilder<LeafSyncWorker>()
            .setInitialDelay(delay, TimeUnit.SECONDS)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .addTag(WORK)
            .build()
        val policy = if (fromJob) ExistingWorkPolicy.APPEND_OR_REPLACE else ExistingWorkPolicy.REPLACE
        WorkManager.getInstance(context).enqueueUniqueWork(WORK, policy, request)
    }

    /** No pass is planned any more: the phone holds no leaf. */
    fun cancel(context: Context) {
        WorkManager.getInstance(context).cancelUniqueWork(WORK)
    }

    fun channels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ARRIVED, "Leaves received", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "A payment received as a leaf"
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_SERVICE, "Leaf sync", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while Ambra keeps its leaves in sync"
            }
        )
    }

    private fun openApp(context: Context): PendingIntent {
        val i = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)
        i.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        return PendingIntent.getActivity(context, 0, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    /** A notification for one coin received; [id] tells two coins apart. */
    fun notifyArrived(context: Context, id: String, title: String, body: String) {
        channels(context)
        val n = NotificationCompat.Builder(context, CHANNEL_ARRIVED)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(openApp(context))
            .setAutoCancel(true)
            .build()
        try {
            NotificationManagerCompat.from(context).notify(id.hashCode(), n)
        } catch (_: SecurityException) {
            // Notifications not allowed: the balance still shows the coin on next open.
        }
    }

    fun serviceNotification(context: Context) =
        NotificationCompat.Builder(context, CHANNEL_SERVICE)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Ambra")
            .setContentText("Keeping your leaves in sync")
            .setContentIntent(openApp(context))
            .setOngoing(true)
            .build()
}
