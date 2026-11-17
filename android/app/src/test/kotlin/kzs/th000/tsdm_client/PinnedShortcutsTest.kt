package kzs.th000.tsdm_client

import android.content.ComponentName
import android.content.Intent
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import android.os.Build
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * A forum or a thread pinned to the home screen opens as the launcher shortcuts of the app icon do: its intent starts
 * the [ShortcutActivity] that is not exported, without [ShortcutKey], which [ShortcutActivity] adds when it hands the
 * shortcut to [MainActivityImpl]. The same intent another app sends to the exported activity is handed to Dart as the
 * link. Pinning the same forum or thread again updates its shortcut.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
class PinnedShortcutsTest {
    private val app get() = RuntimeEnvironment.getApplication()

    /** The app's drawables are not in the test's resources: a bitmap stands for them. */
    private val icon: (String) -> IconCompat = { IconCompat.createWithBitmap(Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)) }

    private fun pins() = PinnedShortcuts(app, icon)

    private val manager get() = app.getSystemService(ShortcutManager::class.java)

    private fun launcherPins(supported: Boolean = true) = shadowOf(manager).setIsRequestPinShortcutSupported(supported)

    @Test
    fun onlyAForumOrAThread() {
        assertTrue(PinnedShortcuts.isPinnableId("forum-1"))
        assertTrue(PinnedShortcuts.isPinnableId("thread-1234567890"))
        for (id in listOf(null, "", "checkin", "forum-0", "forum-01", "forum-", "thread-12345678901", "thread-1/2",
            "thread-1?x", "Thread-1", "post-1", " forum-1")) {
            assertFalse(id.toString(), PinnedShortcuts.isPinnableId(id))
        }
    }

    @Test
    fun theShortcutStartsTheActivityThatIsNotExportedWithoutTheKey() {
        launcherPins()
        ShortcutKey.of(app)
        assertEquals(PinnedShortcuts.REQUESTED, pins().request("thread-42", "Title", "A longer title"))
        val info = manager.pinnedShortcuts.single()
        assertEquals("thread-42", info.id)
        assertEquals("Title", info.shortLabel)
        assertEquals("A longer title", info.longLabel)
        val intent = info.intent!!
        assertEquals(app.packageName, intent.component?.packageName)
        assertEquals(ShortcutActivity::class.java.name, intent.component?.className)
        assertEquals(Intent.ACTION_MAIN, intent.action)
        assertEquals("tsdm://shortcut/thread-42", intent.dataString)
        assertFalse(intent.hasExtra(ShortcutKey.EXTRA))
        assertTrue(intent.extras == null || intent.extras!!.isEmpty)
    }

    @Test
    fun pinningAgainUpdatesTheShortcut() {
        launcherPins()
        assertEquals(PinnedShortcuts.REQUESTED, pins().request("forum-7", "Old", "Old name"))
        assertEquals(PinnedShortcuts.UPDATED, pins().request("forum-7", "New", "New name"))
        val info = manager.pinnedShortcuts.single()
        assertEquals("forum-7", info.id)
        assertEquals("New", info.shortLabel)
        assertEquals("New name", info.longLabel)
    }

    /**
     * A launcher asked to pin a shortcut it has already pins it a second time (Pixel Launcher shows its dialog again and
     * adds a second icon): one pinned is only updated, the launcher is not asked.
     */
    @Test
    fun aPinnedShortcutIsUpdatedWithoutAskingTheLauncher() {
        launcherPins()
        var asked = 0
        val pins = PinnedShortcuts(app, icon, askToPin = {
            asked++
            ShortcutManagerCompat.requestPinShortcut(app, it, null)
        })
        assertEquals(PinnedShortcuts.REQUESTED, pins.request("thread-42", "Old", "Old title"))
        assertEquals(1, asked)
        assertEquals(PinnedShortcuts.UPDATED, pins.request("thread-42", "New", "New title"))
        assertEquals(1, asked)
        val info = manager.pinnedShortcuts.single()
        assertEquals("New", info.shortLabel)
        assertEquals("New title", info.longLabel)
    }

    /** Removed from the home screen (no launcher pins it any more), it is pinned again: the launcher is asked. */
    @Test
    fun oneRemovedFromTheHomeScreenIsPinnedAgain() {
        launcherPins()
        var asked = 0
        var pinned = emptySet<String>()
        val pins = PinnedShortcuts(app, icon, pinnedIds = { pinned }, askToPin = {
            asked++
            true
        })
        assertEquals(PinnedShortcuts.REQUESTED, pins.request("forum-7", "Name", "Name"))
        pinned = setOf("forum-7", "thread-1")
        assertEquals(PinnedShortcuts.UPDATED, pins.request("forum-7", "Name", "Name"))
        pinned = setOf("thread-1")
        assertEquals(PinnedShortcuts.REQUESTED, pins.request("forum-7", "Name", "Name"))
        assertEquals(2, asked)
    }

    /** A launcher that refuses: nothing is reported pinned. */
    @Test
    fun aRefusedRequestIsNoPin() {
        launcherPins()
        assertNull(PinnedShortcuts(app, icon, pinnedIds = { emptySet() }, askToPin = { false }).request("forum-7", "N", "N"))
    }

    /**
     * Switching the app icon disables the alias the pinned shortcuts were tied to (their activity, the main activity
     * when they were pinned), and the launcher removes the items of a disabled component: the forums and threads pinned
     * move to the alias of the new icon. The launcher's own shortcuts (`shortcuts.xml`) cannot be updated and are left.
     */
    @Test
    fun thePinnedForumsAndThreadsMoveToTheIconShown() {
        launcherPins()
        assertEquals(PinnedShortcuts.REQUESTED, pins().request("thread-42", "Thread", "Thread"))
        assertEquals(PinnedShortcuts.REQUESTED, pins().request("forum-7", "Forum", "Forum"))
        val pink = ComponentName(app, "kzs.th000.tsdm_client.IconPink")
        assertEquals(2, PinnedShortcuts.moveTo(app, pink))
        assertEquals(setOf("thread-42", "forum-7"), manager.pinnedShortcuts.map { it.id }.toSet())
        assertEquals(setOf(pink), manager.pinnedShortcuts.map { it.activity }.toSet())
        // Already there: nothing to move.
        assertEquals(0, PinnedShortcuts.moveTo(app, pink))
    }

    @Test
    fun nothingMovesBeforeAndroid8() {
        launcherPins()
        assertEquals(PinnedShortcuts.REQUESTED, pins().request("thread-42", "Thread", "Thread"))
        val pink = ComponentName(app, "kzs.th000.tsdm_client.IconPink")
        assertEquals(0, PinnedShortcuts.moveTo(app, pink, sdk = Build.VERSION_CODES.N_MR1))
    }

    @Test
    fun aMissingLongLabelIsTheShortOne() {
        launcherPins()
        assertEquals(PinnedShortcuts.REQUESTED, pins().request("forum-7", " Name ", " "))
        val info = manager.pinnedShortcuts.single()
        assertEquals("Name", info.shortLabel)
        assertEquals("Name", info.longLabel)
    }

    @Test
    fun aLongLabelIsCutAndNeverInsideAPair() {
        launcherPins()
        val label = "a".repeat(99) + "😀" + "b".repeat(10)
        assertEquals(PinnedShortcuts.REQUESTED, pins().request("forum-7", label, label))
        assertEquals("a".repeat(99), manager.pinnedShortcuts.single().shortLabel.toString())
    }

    @Test
    fun nothingIsPinnedWithoutALauncherThatPins() {
        launcherPins(false)
        assertFalse(PinnedShortcuts.supported(app))
        assertNull(pins().request("forum-1", "Name", "Name"))
        assertTrue(manager.pinnedShortcuts.isEmpty())
    }

    @Test
    fun notBeforeAndroid8() {
        launcherPins()
        assertTrue(PinnedShortcuts.supported(app))
        assertFalse(PinnedShortcuts.supported(app, sdk = Build.VERSION_CODES.N_MR1))
    }

    @Test
    fun nothingIsPinnedForAnotherIdOrWithoutALabel() {
        launcherPins()
        assertNull(pins().request("checkin", "Name", "Name"))
        assertNull(pins().request("forum-1", "  ", "Name"))
        assertNull(pins().request("forum-1", null, "Name"))
        assertNull(pins().request(null, "Name", "Name"))
        assertTrue(manager.pinnedShortcuts.isEmpty())
    }

    @Test
    fun theTwoIcons() {
        assertEquals(R.drawable.ic_shortcut_forum, PinnedShortcuts.iconResOf("forum-1"))
        assertEquals(R.drawable.ic_shortcut_thread, PinnedShortcuts.iconResOf("thread-1"))
    }

    @Test
    fun theLauncherStartsItAndTheKeyIsAddedOnTheWay() {
        val shortcut = PinnedShortcuts.intentOf(app, "thread-42")
        val controller = Robolectric.buildActivity(ShortcutActivity::class.java, shortcut).create()
        val started = shadowOf(controller.get()).nextStartedActivity
        assertNotNull(started)
        assertEquals(MainActivityImpl::class.java.name, started.component?.className)
        assertEquals("tsdm://shortcut/thread-42", started.dataString)
        assertEquals("thread-42", ShortcutsHandler.shortcutIdOf(started, ShortcutKey.of(app)))
        assertTrue(controller.get().isFinishing)
    }

    @Test
    fun theSameIntentFromAnotherAppIsTheLink() {
        val sent = Intent(PinnedShortcuts.intentOf(app, "thread-42")).setClass(app, MainActivityImpl::class.java)
        assertEquals("tsdm://shortcut/thread-42", ShortcutsHandler.shortcutIdOf(sent, ShortcutKey.of(app)))
    }

    @Test
    fun theChannelCallsItDoesNotAnswerAreLeftToTheHandler() {
        launcherPins()
        var answer: Any? = "unset"
        val result = object : io.flutter.plugin.common.MethodChannel.Result {
            override fun success(result: Any?) {
                answer = result
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) = fail(errorCode)
            override fun notImplemented() = fail("notImplemented")
        }
        assertTrue(pins().handle(io.flutter.plugin.common.MethodCall(PinnedShortcuts.IS_SUPPORTED, null), result))
        assertEquals(true, answer)
        val request = mapOf("id" to "forum-3", "shortLabel" to "Name", "longLabel" to "Name")
        assertTrue(pins().handle(io.flutter.plugin.common.MethodCall(PinnedShortcuts.REQUEST, request), result))
        assertEquals(PinnedShortcuts.REQUESTED, answer)
        assertTrue(pins().handle(io.flutter.plugin.common.MethodCall(PinnedShortcuts.REQUEST, "forum-3"), result))
        assertNull(answer)
        assertFalse(pins().handle(io.flutter.plugin.common.MethodCall(ShortcutsHandler.GET_INITIAL_SHORTCUT, null), result))
    }
}
