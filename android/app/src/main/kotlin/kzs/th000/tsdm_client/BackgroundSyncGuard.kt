package kzs.th000.tsdm_client

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import id.flutter.flutter_background_service.BackgroundService

/**
 * Keeps an eye on the background message service (flutter_background_service's [BackgroundService]) while the app
 * wants it running, so that it never stops without the user knowing (P13).
 *
 * When the system kills the process, the plugin's watchdog alarm tries to start the foreground service again. On
 * Android 12+ an app in the background may not start one (`ForegroundServiceStartNotAllowedException`) unless it is
 * exempted from battery optimizations, or an exact alarm, a high priority push, the boot broadcast… started it: the
 * watchdog's alarm is an inexact one, so it is refused and nothing polls until the app is opened.
 *
 * This job (JobScheduler, part of the platform: no new dependency) runs every 15 minutes or so while the service is
 * wanted. It starts the service again where it may (before Android 12, or with the exemption); where the system
 * refuses, it posts one quiet notification (the channel of the service's own notification) whose tap opens the app,
 * which starts the service in the foreground. [onActivityResumed] does the same when the app comes to the front while
 * the process outlived the service.
 *
 * Dart says when the service is wanted ([setWanted], from `BackgroundSyncController`): a switch turned off or an
 * interval set to "never" cancels the job and the notification.
 */
class BackgroundSyncGuard : JobService() {
    /** What [check] does for the service's state. */
    enum class Step {
        /** Not wanted: the job and the notification go. */
        STOP_GUARDING,

        /** Running: nothing to do (a notification about an earlier stop goes). */
        NOTHING,

        /** Wanted and gone: start it again. */
        RESTART,
    }

    companion object {
        /** android.util.Log, not Flutter's: a release build keeps these lines in the logcat for checking on a device. */
        private const val TAG = "BG_SYNC_GUARD"
        private const val PREFS = "kzs.th000.tsdm_client.background_sync_guard"
        private const val KEY_WANTED = "wanted"
        private const val KEY_NOTIFIED = "notified"
        private const val KEY_TITLE = "title"

        /** Far from the ids JobScheduler users of the plugins hand out (WorkManager counts up from 0). */
        const val JOB_ID = 0x75D30001

        /** The service's own channel (`backgroundSyncChannelId`, made by Dart): low importance, no sound. */
        const val CHANNEL_ID = "tsdm_foreground"

        /** Next to the service's notification (`backgroundSyncNotificationId`, 888). */
        const val NOTIFICATION_ID = 889

        /** The shortest period JobScheduler allows. */
        const val PERIOD_MS = 15 * 60 * 1000L

        private fun prefs(context: Context): SharedPreferences =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        /**
         * Whether the background service should run ([wanted]), told by Dart each time it brought the service in line
         * with the settings. [title] is the text of the notification posted when the system refuses to start it again,
         * in the language of the app.
         */
        fun setWanted(context: Context, wanted: Boolean, title: String?) {
            val editor = prefs(context).edit()
                .putBoolean(KEY_WANTED, wanted)
                .putBoolean(KEY_NOTIFIED, false)
            if (!title.isNullOrBlank()) editor.putString(KEY_TITLE, title)
            editor.apply()
            clearNotice(context)
            val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as? JobScheduler ?: return
            try {
                if (!wanted) {
                    scheduler.cancel(JOB_ID)
                } else if (scheduler.allPendingJobs.none { it.id == JOB_ID }) {
                    val job = JobInfo.Builder(JOB_ID, ComponentName(context, BackgroundSyncGuard::class.java))
                        .setPeriodic(PERIOD_MS)
                        // Kept over a reboot (RECEIVE_BOOT_COMPLETED is in the manifest).
                        .setPersisted(true)
                        .build()
                    scheduler.schedule(job)
                }
            } catch (e: Exception) {
                Log.e(TAG, "job not scheduled: ${e.message}")
            }
        }

        fun decide(wanted: Boolean, running: Boolean): Step = when {
            !wanted -> Step.STOP_GUARDING
            running -> Step.NOTHING
            else -> Step.RESTART
        }

        /** Whether the plugin's service runs in this app (an app sees its own services). */
        fun serviceRunning(context: Context): Boolean {
            val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return false
            @Suppress("DEPRECATION")
            return manager.getRunningServices(Int.MAX_VALUE).any {
                it.service.className == BackgroundService::class.java.name
            }
        }

        private fun startService(context: Context) =
            ContextCompat.startForegroundService(context, Intent(context, BackgroundService::class.java))

        /**
         * Start the service again when it is wanted and gone; tell the user once when the system refuses. Returns what
         * was decided.
         *
         * [inFront] is true when an activity of the app is in front: the system never refuses then, and no
         * notification is posted for a failure.
         */
        fun check(
            context: Context,
            inFront: Boolean = false,
            running: (Context) -> Boolean = ::serviceRunning,
            start: (Context) -> Unit = ::startService,
        ): Step {
            val prefs = prefs(context)
            val step = decide(prefs.getBoolean(KEY_WANTED, false), running(context))
            when (step) {
                Step.STOP_GUARDING -> {
                    (context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as? JobScheduler)?.cancel(JOB_ID)
                    clearNotice(context)
                }
                Step.NOTHING -> if (prefs.getBoolean(KEY_NOTIFIED, false)) {
                    prefs.edit().putBoolean(KEY_NOTIFIED, false).apply()
                    clearNotice(context)
                }
                Step.RESTART -> try {
                    start(context)
                    Log.i(TAG, "background service restarted (in front: $inFront)")
                    if (prefs.getBoolean(KEY_NOTIFIED, false)) {
                        prefs.edit().putBoolean(KEY_NOTIFIED, false).apply()
                        clearNotice(context)
                    }
                } catch (e: Exception) {
                    // ForegroundServiceStartNotAllowedException (Android 12+), an IllegalStateException; a
                    // SecurityException when a permission is missing.
                    Log.w(TAG, "background service not restarted: ${e.javaClass.simpleName}: ${e.message}")
                    if (!inFront && !prefs.getBoolean(KEY_NOTIFIED, false)) {
                        if (postNotice(context, prefs.getString(KEY_TITLE, null))) {
                            prefs.edit().putBoolean(KEY_NOTIFIED, true).apply()
                        }
                    }
                }
            }
            return step
        }

        /** An activity of the app came to the front: the service is started again if it went while the process lived. */
        fun onActivityResumed(context: Context) {
            try {
                check(context, inFront = true)
            } catch (e: Exception) {
                Log.e(TAG, "check on resume failed: ${e.message}")
            }
        }

        private fun postNotice(context: Context, title: String?): Boolean {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return false
            // Notifications off (no permission on Android 13+, or turned off): the settings page still shows the
            // state; posted once they are back.
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return false
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) flags = flags or PendingIntent.FLAG_IMMUTABLE
            val tap = PendingIntent.getActivity(context, NOTIFICATION_ID, launch, flags)
            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_launcher_foreground)
                .setContentTitle(title ?: context.applicationInfo.loadLabel(context.packageManager))
                .setContentIntent(tap)
                .setAutoCancel(true)
                .setCategory(Notification.CATEGORY_STATUS)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build()
            return try {
                manager.notify(NOTIFICATION_ID, notification)
                Log.i(TAG, "stopped notice posted")
                true
            } catch (e: Exception) {
                Log.w(TAG, "stopped notice not posted: ${e.message}")
                false
            }
        }

        private fun clearNotice(context: Context) {
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager)?.cancel(NOTIFICATION_ID)
        }
    }

    override fun onStartJob(params: JobParameters?): Boolean {
        try {
            check(applicationContext)
        } catch (e: Exception) {
            Log.e(TAG, "check failed: ${e.message}")
        }
        // Done: nothing runs on after this returns.
        return false
    }

    override fun onStopJob(params: JobParameters?): Boolean = false
}
