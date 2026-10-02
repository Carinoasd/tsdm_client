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
import java.io.File
import java.util.regex.Pattern

/** Real production Flutter download page and real Android permission / package installer UI. */
@RunWith(AndroidJUnit4::class)
class UpdateInstallerDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(instrumentation)

    private fun click(text: String, timeout: Long = 30000) {
        val deadline = System.currentTimeMillis() + timeout
        var node = device.findObject(By.textContains(text)) ?: device.findObject(By.descContains(text))
        while (node == null && System.currentTimeMillis() < deadline) {
            device.swipe(device.displayWidth / 2, device.displayHeight * 4 / 5,
                device.displayWidth / 2, device.displayHeight / 3, 15)
            Thread.sleep(500)
            node = device.findObject(By.textContains(text)) ?: device.findObject(By.descContains(text))
        }
        checkNotNull(node) { "Missing update action: $text" }.click()
        device.waitForIdle()
    }

    private fun screenshot(name: String) {
        val output = File(instrumentation.targetContext.getExternalFilesDir(null), "emulator-evidence")
        output.mkdirs()
        assertTrue(device.takeScreenshot(File(output, "$name.png")))
        device.dumpWindowHierarchy(File(output, "$name.xml"))
    }

    @Test fun downloadOfficialApkAndOpenSystemInstaller() {
        val context = instrumentation.targetContext
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        assertEquals("Only disposable lower-version emulator build may run this test", 1199L, info.longVersionCode)
        assertFalse("Fresh emulator must not pre-grant unknown-source installation", context.packageManager.canRequestPackageInstalls())
        context.startActivity(Intent().setClassName(context.packageName, "kzs.th000.tsdm_client.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        screenshot("update-start")
        click("Download APK (1.30.0)", 60000)
        screenshot("update-download")
        // Production downloader streams the actual official GitHub APK and verifies its SHA-256.
        click("Install update", 300000)
        click("Open installation settings")
        assertTrue(device.wait(Until.hasObject(By.pkg("com.android.settings")), 10000))
        screenshot("update-permission")
        val allow = checkNotNull(device.wait(Until.findObject(By.text("Allow from this source")), 10000)) { "Expected Android per-app installation permission" }
        allow.click()
        device.pressBack()
        device.waitForIdle()
        assertTrue(context.packageManager.canRequestPackageInstalls())
        click("Retry installation")
        assertTrue("Android must show its own installer confirmation", device.wait(Until.hasObject(By.text(Pattern.compile("(?i)INSTALL|UPDATE"))), 30000))
        screenshot("update-installer-confirmation")
        // The host script confirms installation after instrumentation exits, because updating
        // this package terminates its instrumentation process. It then asserts versionCode1209.
    }
}
