package kzs.th000.tsdm_client

import android.content.Intent
import android.net.Uri
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * A `tsdm://shortcut/<id>` intent checks in or opens a page: [MainActivityImpl] and its launcher aliases are exported, so
 * another app may send it. Only the app's own shortcuts (the launcher's through [ShortcutActivity], the widget's)
 * carry [ShortcutKey] and are handed to Dart as the id; the rest as the link, which Dart only opens as a page.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
class ShortcutsHandlerTest {
    private val app get() = RuntimeEnvironment.getApplication()

    private fun shortcut(id: String, key: String? = null) = Intent(Intent.ACTION_MAIN)
        .setData(Uri.parse("tsdm://shortcut/$id"))
        .apply { if (key != null) putExtra(ShortcutKey.EXTRA, key) }

    @Test
    fun theKeyIsMadeOnceAndKept() {
        val key = ShortcutKey.of(app)
        assertTrue(key.matches(Regex("[0-9a-f]{32}")))
        assertEquals(key, ShortcutKey.of(app))
    }

    @Test
    fun theAppsOwnShortcutIsTheId() {
        val key = ShortcutKey.of(app)
        assertEquals("checkin", ShortcutsHandler.shortcutIdOf(shortcut("checkin", key), key))
        assertEquals("notice", ShortcutsHandler.shortcutIdOf(shortcut("notice", key), key))
    }

    @Test
    fun anotherAppsIntentIsTheLink() {
        val key = ShortcutKey.of(app)
        assertEquals("tsdm://shortcut/checkin", ShortcutsHandler.shortcutIdOf(shortcut("checkin"), key))
        assertEquals("tsdm://shortcut/checkin", ShortcutsHandler.shortcutIdOf(shortcut("checkin", "0".repeat(32)), key))
        assertEquals("tsdm://shortcut/checkin", ShortcutsHandler.shortcutIdOf(shortcut("checkin", ""), ""))
        assertEquals("tsdm://shortcut/checkin", ShortcutsHandler.shortcutIdOf(shortcut("checkin", key), null))
    }

    @Test
    fun noShortcut() {
        val key = ShortcutKey.of(app)
        assertNull(ShortcutsHandler.shortcutIdOf(null, key))
        assertNull(ShortcutsHandler.shortcutIdOf(shortcut("checkin", key).setAction(Intent.ACTION_VIEW), key))
        assertNull(ShortcutsHandler.shortcutIdOf(Intent(Intent.ACTION_MAIN).setData(Uri.parse("https://x/")), key))
        val replay = shortcut("checkin", key).addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)
        assertNull(ShortcutsHandler.shortcutIdOf(replay, key))
    }

    @Test
    fun theLauncherShortcutIsForwardedWithTheKey() {
        val controller = Robolectric.buildActivity(ShortcutActivity::class.java, shortcut("checkin")).create()
        val started = shadowOf(controller.get()).nextStartedActivity
        assertNotNull(started)
        assertEquals(MainActivityImpl::class.java.name, started.component?.className)
        assertEquals(Intent.ACTION_MAIN, started.action)
        assertEquals("tsdm://shortcut/checkin", started.dataString)
        assertEquals("checkin", ShortcutsHandler.shortcutIdOf(started, ShortcutKey.of(app)))
        assertTrue(controller.get().isFinishing)
    }

    @Test
    fun anythingElseIsNotForwarded() {
        val controller = Robolectric
            .buildActivity(ShortcutActivity::class.java, Intent(Intent.ACTION_VIEW, Uri.parse("https://x/")))
            .create()
        assertNull(shadowOf(controller.get()).nextStartedActivity)
        assertTrue(controller.get().isFinishing)
    }
}
