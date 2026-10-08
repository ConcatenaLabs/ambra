package io.sequentia.ambra

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Keeps the app's process alive while it runs with a leaf wallet open, so the
 * wallet's own schedule (driven from Dart, on the library's `next_sync_at`) keeps
 * syncing when the app is in the background. It holds no wallet itself; once the
 * app is gone, [LeafSyncWorker] takes over.
 */
class LeafSyncService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        LeafJobs.channels(this)
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
        ServiceCompat.startForeground(this, NOTIFICATION, LeafJobs.serviceNotification(this), type)
        return START_NOT_STICKY
    }

    /** The app was swiped away: the scheduled job syncs from now on. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // The system's daily allowance for a data-sync service ran out: the
        // scheduled job carries on.
        stopSelf()
    }

    companion object {
        private const val NOTIFICATION = 7301

        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, LeafSyncService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, LeafSyncService::class.java))
        }
    }
}
