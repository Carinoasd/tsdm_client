package kzs.th000.tsdm_client

import android.app.NotificationManager
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** P13: the background message service never stops without the user knowing. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 31, 35], manifest = Config.NONE)
class BackgroundSyncGuardTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val scheduler get() = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
    private val notifications get() = shadowOf(context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
    private var starts = 0

    private val refused: (Context) -> Unit = {
        starts++
        throw IllegalStateException("startForegroundService() not allowed due to mAllowStartForeground false")
    }
    private val started: (Context) -> Unit = { starts++ }

    @Before fun launcher() {
        // The notification's tap opens the app's launcher entry.
        val component = ComponentName(context.packageName, "${context.packageName}.Main")
        val pm = shadowOf(context.packageManager)
        pm.addActivityIfNotPresent(component)
        pm.addIntentFilterForActivity(component, IntentFilter(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
            addCategory(Intent.CATEGORY_DEFAULT)
        })
    }

    @Test fun decideTable() {
        assertEquals(BackgroundSyncGuard.Step.STOP_GUARDING, BackgroundSyncGuard.decide(false, false))
        assertEquals(BackgroundSyncGuard.Step.STOP_GUARDING, BackgroundSyncGuard.decide(false, true))
        assertEquals(BackgroundSyncGuard.Step.NOTHING, BackgroundSyncGuard.decide(true, true))
        assertEquals(BackgroundSyncGuard.Step.RESTART, BackgroundSyncGuard.decide(true, false))
    }

    @Test fun wantedSchedulesOnePeriodicPersistedJob() {
        BackgroundSyncGuard.setWanted(context, true, "stopped")
        BackgroundSyncGuard.setWanted(context, true, "stopped")
        val jobs = scheduler.allPendingJobs
        assertEquals(1, jobs.size)
        val job = jobs.single()
        assertEquals(BackgroundSyncGuard.JOB_ID, job.id)
        assertTrue(job.isPeriodic)
        assertEquals(BackgroundSyncGuard.PERIOD_MS, job.intervalMillis)
        assertTrue(job.isPersisted)
        assertEquals(BackgroundSyncGuard::class.java.name, job.service.className)
    }

    @Test fun notWantedCancelsTheJobAndNeverStarts() {
        BackgroundSyncGuard.setWanted(context, true, "stopped")
        BackgroundSyncGuard.setWanted(context, false, null)
        assertTrue(scheduler.allPendingJobs.isEmpty())
        BackgroundSyncGuard.check(context, running = { false }, start = started)
        assertEquals(0, starts)
        assertTrue(notifications.allNotifications.isEmpty())
    }

    @Test fun runningServiceIsLeftAlone() {
        BackgroundSyncGuard.setWanted(context, true, "stopped")
        val step = BackgroundSyncGuard.check(context, running = { true }, start = started)
        assertEquals(BackgroundSyncGuard.Step.NOTHING, step)
        assertEquals(0, starts)
    }

    @Test fun goneServiceIsStartedAgainWhereAllowed() {
        BackgroundSyncGuard.setWanted(context, true, "stopped")
        BackgroundSyncGuard.check(context, running = { false }, start = started)
        assertEquals(1, starts)
        assertTrue(notifications.allNotifications.isEmpty())
    }

    @Test fun refusedRestartPostsOneNoticeWithTheTitleFromDart() {
        BackgroundSyncGuard.setWanted(context, true, "后台消息接收已被系统停止")
        BackgroundSyncGuard.check(context, running = { false }, start = refused)
        val posted = notifications.getNotification(BackgroundSyncGuard.NOTIFICATION_ID)
        assertNotNull(posted)
        assertEquals("后台消息接收已被系统停止", posted.extras.getCharSequence("android.title").toString())
        assertNotNull(posted.contentIntent)
        // Dismissed by the user: not posted again for the same stop, every quarter of an hour.
        notifications.cancelAll()
        BackgroundSyncGuard.check(context, running = { false }, start = refused)
        assertEquals(2, starts)
        assertTrue(notifications.allNotifications.isEmpty())
    }

    @Test fun serviceBackClearsTheNotice() {
        BackgroundSyncGuard.setWanted(context, true, "stopped")
        BackgroundSyncGuard.check(context, running = { false }, start = refused)
        assertNotNull(notifications.getNotification(BackgroundSyncGuard.NOTIFICATION_ID))
        BackgroundSyncGuard.check(context, running = { true }, start = started)
        assertNull(notifications.getNotification(BackgroundSyncGuard.NOTIFICATION_ID))
        // A later stop is told again.
        BackgroundSyncGuard.check(context, running = { false }, start = refused)
        assertNotNull(notifications.getNotification(BackgroundSyncGuard.NOTIFICATION_ID))
    }

    @Test fun inFrontNeverPosts() {
        BackgroundSyncGuard.setWanted(context, true, "stopped")
        BackgroundSyncGuard.check(context, inFront = true, running = { false }, start = refused)
        assertEquals(1, starts)
        assertTrue(notifications.allNotifications.isEmpty())
    }

    @Test fun switchedOffClearsTheNotice() {
        BackgroundSyncGuard.setWanted(context, true, "stopped")
        BackgroundSyncGuard.check(context, running = { false }, start = refused)
        BackgroundSyncGuard.setWanted(context, false, null)
        assertNull(notifications.getNotification(BackgroundSyncGuard.NOTIFICATION_ID))
    }

    @Test fun backingOffDoublesAndCaps() {
        val p = BackgroundSyncGuard.PERIOD_MS
        assertFalse(BackgroundSyncGuard.backingOff(0, 0L, 0L))
        assertFalse(BackgroundSyncGuard.backingOff(1, 0L, p))
        assertTrue(BackgroundSyncGuard.backingOff(2, 0L, p))
        assertFalse(BackgroundSyncGuard.backingOff(2, 0L, 2 * p))
        assertTrue(BackgroundSyncGuard.backingOff(3, 0L, 3 * p))
        assertFalse(BackgroundSyncGuard.backingOff(3, 0L, 4 * p))
        assertTrue(BackgroundSyncGuard.backingOff(50, 0L, 31 * p))
        assertFalse(BackgroundSyncGuard.backingOff(50, 0L, 32 * p))
        // The clock set back: not waiting for the step back.
        assertFalse(BackgroundSyncGuard.backingOff(3, 10 * p, 0L))
    }

    @Test fun serviceThatStopsItselfIsNotRestartedEveryPeriod() {
        BackgroundSyncGuard.setWanted(context, true, "stopped")
        val p = BackgroundSyncGuard.PERIOD_MS
        var clock = 0L
        fun tick() = BackgroundSyncGuard.check(context, running = { false }, start = started, now = { clock })
        fun front() =
            BackgroundSyncGuard.check(context, inFront = true, running = { false }, start = started, now = { clock })
        tick() // First restart, at 0.
        clock += p
        tick() // Gone again: second restart, one period later (at p).
        assertEquals(2, starts)
        clock += p
        assertEquals(BackgroundSyncGuard.Step.WAITING, tick()) // Two periods to wait now.
        assertEquals(2, starts)
        clock += p
        assertEquals(BackgroundSyncGuard.Step.RESTART, tick()) // At 3p.
        assertEquals(3, starts)
        // The app coming to the front waits too (it comes many times in a session), a period at most.
        clock += p / 2
        assertEquals(BackgroundSyncGuard.Step.WAITING, front())
        assertEquals(3, starts)
        clock += p / 2
        assertEquals(BackgroundSyncGuard.Step.WAITING, tick()) // The job: four periods now.
        assertEquals(BackgroundSyncGuard.Step.RESTART, front())
        assertEquals(4, starts)
    }

    @Test fun seenRunningOrToldAgainStartsTheCountOver() {
        BackgroundSyncGuard.setWanted(context, true, "stopped")
        val p = BackgroundSyncGuard.PERIOD_MS
        var clock = 0L
        fun tick(up: Boolean = false) =
            BackgroundSyncGuard.check(context, running = { up }, start = started, now = { clock })
        tick(); clock += p; tick(); clock += p
        tick(up = true)
        tick()
        assertEquals(3, starts)
        clock += p / 2
        BackgroundSyncGuard.setWanted(context, true, "stopped")
        tick()
        assertEquals(4, starts)
    }
}
