package kzs.th000.tsdm_client

import android.content.ComponentName
import android.content.pm.PackageManager
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import androidx.core.graphics.drawable.IconCompat
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Switching the app icon enables the alias of the new icon and disables the others. The forums and threads pinned to
 * the home screen are tied to the alias that was enabled when they were pinned; the launcher removes them with it
 * unless they are moved to the new alias first, while both are enabled.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
class AppIconSwitcherTest {
    private val app get() = RuntimeEnvironment.getApplication()

    private fun alias(name: String) = ComponentName(app, "kzs.th000.tsdm_client.$name")

    private fun stateOf(name: String) = app.packageManager.getComponentEnabledSetting(alias(name))

    @Test
    fun theShortcutsMoveWhileTheOldAndTheNewIconAreBothEnabled() {
        var movedTo: ComponentName? = null
        var newState = -1
        var oldState = -1
        assertTrue(AppIconSwitcher.apply(app, "pink") {
            movedTo = it
            newState = stateOf("IconPink")
            oldState = stateOf("MainActivity")
        })
        assertEquals(alias("IconPink"), movedTo)
        assertEquals(PackageManager.COMPONENT_ENABLED_STATE_ENABLED, newState)
        // Not set yet: the manifest's default, enabled for MainActivity.
        assertNotEquals(PackageManager.COMPONENT_ENABLED_STATE_DISABLED, oldState)
        assertEquals(PackageManager.COMPONENT_ENABLED_STATE_DISABLED, stateOf("MainActivity"))
        assertEquals(PackageManager.COMPONENT_ENABLED_STATE_ENABLED, stateOf("IconPink"))
    }

    @Test
    fun switchingTheIconKeepsThePinnedShortcuts() {
        val manager = app.getSystemService(ShortcutManager::class.java)
        shadowOf(manager).setIsRequestPinShortcutSupported(true)
        val pins = PinnedShortcuts(app, { IconCompat.createWithBitmap(Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)) })
        assertEquals(PinnedShortcuts.REQUESTED, pins.request("thread-42", "Thread", "Thread"))
        assertTrue(AppIconSwitcher.apply(app, "dark"))
        assertEquals(alias("IconDark"), manager.pinnedShortcuts.single().activity)
        assertTrue(AppIconSwitcher.apply(app, "default"))
        assertEquals(alias("MainActivity"), manager.pinnedShortcuts.single().activity)
    }

    /** Each start of the app applies the icon shown: nothing to switch, nothing to move. */
    @Test
    fun theIconShownAlreadyMovesNothing() {
        var moved = 0
        assertTrue(AppIconSwitcher.apply(app, "default") { moved++ })
        assertEquals(0, moved)
        assertTrue(AppIconSwitcher.apply(app, "mono") { moved++ })
        assertEquals(1, moved)
        assertTrue(AppIconSwitcher.apply(app, "mono") { moved++ })
        assertEquals(1, moved)
        assertEquals(PackageManager.COMPONENT_ENABLED_STATE_ENABLED, stateOf("IconMono"))
        assertEquals(PackageManager.COMPONENT_ENABLED_STATE_DISABLED, stateOf("MainActivity"))
    }

    @Test
    fun anUnknownIconChangesNothing() {
        var moved = false
        assertFalse(AppIconSwitcher.apply(app, "green") { moved = true })
        assertFalse(moved)
        assertNotEquals(PackageManager.COMPONENT_ENABLED_STATE_DISABLED, stateOf("MainActivity"))
    }
}
