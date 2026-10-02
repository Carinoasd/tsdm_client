package kzs.th000.tsdm_client

import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.regex.Pattern

abstract class UpdateDeviceActions {
    protected val instrumentation = InstrumentationRegistry.getInstrumentation()
    protected val device = UiDevice.getInstance(instrumentation)

    protected fun click(text: String, timeout: Long = 30000) {
        val deadline = System.currentTimeMillis() + timeout
        // Guidance text quotes these same labels; only tap the actionable button.
        var node = device.findObject(By.text(text).clickable(true)) ?: device.findObject(By.desc(text).clickable(true))
        while (node == null && System.currentTimeMillis() < deadline) {
            device.swipe(device.displayWidth / 2, device.displayHeight * 4 / 5,
                device.displayWidth / 2, device.displayHeight / 3, 15)
            Thread.sleep(500)
            node = device.findObject(By.text(text).clickable(true)) ?: device.findObject(By.desc(text).clickable(true))
        }
        checkNotNull(node) { "Missing update action: $text" }.click()
        device.waitForIdle()
    }

    protected fun screenshot(name: String) = EmulatorEvidence.capture(device, name, hierarchy = true)

    protected fun launch() {
        val context = instrumentation.targetContext
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        assertEquals("Only disposable lower-version emulator build may run this test", 1199L, info.longVersionCode)
        context.startActivity(Intent().setClassName(context.packageName, "kzs.th000.tsdm_client.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}

/** End before permission changes: Android kills the target process when the app-op changes. */
@RunWith(AndroidJUnit4::class)
class UpdateInstallerDeviceTest : UpdateDeviceActions() {
    @Test fun downloadOfficialApkAndOpenPermissionSettings() {
        val context = instrumentation.targetContext
        assertFalse("Fresh emulator must not pre-grant unknown-source installation", context.packageManager.canRequestPackageInstalls())
        launch()
        screenshot("update-start")
        click("Download APK (1.30.0)", 60000)
        screenshot("update-download")
        // Production downloader streams the actual official GitHub APK and verifies its SHA-256.
        click("Install update", 300000)
        click("Open installation settings")
        assertTrue(device.wait(Until.hasObject(By.pkg("com.android.settings")), 10000))
        screenshot("update-permission")
        assertTrue(device.wait(Until.hasObject(By.text("Allow from this source")), 10000))
        // Host clicks the real Settings toggle after instrumentation has exited.
    }
}

/** Fresh process must recover a verified download and wait for another explicit install tap. */
@RunWith(AndroidJUnit4::class)
class UpdateInstallerResumeDeviceTest : UpdateDeviceActions() {
    @Test fun recoverVerifiedApkAfterPermissionProcessDeath() {
        assertTrue(instrumentation.targetContext.packageManager.canRequestPackageInstalls())
        launch()
        // Do not download again: this button must come from verified cache recovery.
        click("Install update", 90000)
        assertTrue("Android must show its own installer confirmation", device.wait(Until.hasObject(By.text(Pattern.compile("(?i)INSTALL|UPDATE"))), 30000))
        screenshot("update-installer-confirmation")
        // The host script confirms installation after instrumentation exits, because updating
        // this package terminates its instrumentation process. It then asserts versionCode1209.
    }
}
