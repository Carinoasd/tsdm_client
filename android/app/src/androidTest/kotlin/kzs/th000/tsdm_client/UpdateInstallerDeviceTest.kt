package kzs.th000.tsdm_client

import android.content.Intent
import android.os.SystemClock
import android.util.Log
import android.view.View
import android.view.ViewGroup
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import io.flutter.embedding.android.FlutterView
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.regex.Pattern

abstract class UpdateDeviceActions {
    protected val instrumentation = InstrumentationRegistry.getInstrumentation()
    protected val device = UiDevice.getInstance(instrumentation)
    private var currentPhase = "start"

    protected fun phase(name: String) {
        currentPhase = name
        Log.i("UpdateInstallerTest", "Starting $name")
    }

    protected fun withFailureEvidence(block: () -> Unit) {
        try {
            block()
        } catch (failure: Throwable) {
            Log.e("UpdateInstallerTest", "Failed during $currentPhase", failure)
            try {
                screenshot("update-failure-$currentPhase")
            } catch (diagnosticFailure: Exception) {
                failure.addSuppressed(diagnosticFailure)
            }
            throw failure
        }
    }

    private fun button(text: String) =
        device.findObject(By.text(text).clickable(true).enabled(true))
            ?: device.findObject(By.desc(text).clickable(true).enabled(true))

    protected fun click(text: String, timeout: Long = 30000) {
        val deadline = System.currentTimeMillis() + timeout
        // Guidance text quotes these same labels; only tap the actionable button.
        var node = button(text)
        while (node == null && System.currentTimeMillis() < deadline) {
            check(text != "Install update" || button("Retry download (1.30.0)") == null) {
                "Production APK download failed during $currentPhase; see failure screenshot and hierarchy"
            }
            device.swipe(device.displayWidth / 2, device.displayHeight * 4 / 5,
                device.displayWidth / 2, device.displayHeight / 3, 15)
            Thread.sleep(500)
            node = button(text)
        }
        checkNotNull(node) { "Missing update action during $currentPhase: $text" }.click()
        device.waitForIdle()
    }

    protected fun waitForDownloadStarted() {
        val deadline = SystemClock.uptimeMillis() + 10000
        while (SystemClock.uptimeMillis() < deadline) {
            // These are production state messages, not just an injected tap or
            // a vanished button. Do not scroll or repeat the download action.
            val started = listOf("Finding the APK for this version…", "Downloading APK…",
                "Verifying the downloaded APK…", "The APK is ready.").any {
                device.hasObject(By.descContains(it)) || device.hasObject(By.textContains(it))
            }
            if (started) return
            check(button("Retry download (1.30.0)") == null) { "Production APK download failed to start" }
            Thread.sleep(100)
        }
        error("Download tap did not enter a production download state during $currentPhase")
    }

    protected fun screenshot(name: String) = EmulatorEvidence.capture(device, name, hierarchy = true)

    protected fun launch() {
        val context = instrumentation.targetContext
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        assertEquals("Only disposable lower-version emulator build may run this test", 1199L, info.longVersionCode)
        context.startActivity(Intent().setClassName(context.packageName, "kzs.th000.tsdm_client.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        waitForFlutterFrame()
    }

    private fun flutterView(view: View): FlutterView? {
        if (view is FlutterView) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) {
            flutterView(view.getChildAt(index))?.let { return it }
        }
        return null
    }

    private fun waitForFlutterFrame() {
        val deadline = SystemClock.uptimeMillis() + 30000
        var lastState = "No resumed MainActivity"
        while (SystemClock.uptimeMillis() < deadline) {
            var ready = false
            instrumentation.runOnMainSync {
                val activity = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                    .filterIsInstance<MainActivity>().singleOrNull()
                if (activity != null) {
                    val view = flutterView(activity.window.decorView)
                    val rendered = view?.hasRenderedFirstFrame() == true
                    val focused = activity.hasWindowFocus()
                    lastState = "activity=$activity, firstFrame=$rendered, windowFocus=$focused"
                    ready = rendered && focused && view?.isShown == true && !activity.isFinishing
                }
            }
            if (ready) {
                // Flutter semantics can precede the native first draw, leaving
                // the launch window on top of an apparently clickable button.
                instrumentation.waitForIdleSync()
                device.waitForIdle()
                Log.i("UpdateInstallerTest", "Flutter is displayed: $lastState")
                return
            }
            Thread.sleep(50)
        }
        error("Flutter did not display during $currentPhase: $lastState")
    }
}

/** End before permission changes: Android kills the target process when the app-op changes. */
@RunWith(AndroidJUnit4::class)
class UpdateInstallerDeviceTest : UpdateDeviceActions() {
    @Test fun downloadOfficialApkAndOpenPermissionSettings() = withFailureEvidence {
        phase("launch-download-page")
        val context = instrumentation.targetContext
        assertFalse("Fresh emulator must not pre-grant unknown-source installation", context.packageManager.canRequestPackageInstalls())
        launch()
        screenshot("update-start")
        phase("start-download")
        click("Download APK (1.30.0)", 60000)
        waitForDownloadStarted()
        screenshot("update-download")
        // Production downloader streams the actual official GitHub APK and verifies its SHA-256.
        phase("download-and-verification")
        click("Install update", 300000)
        phase("open-permission-settings")
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
    @Test fun recoverVerifiedApkAfterPermissionProcessDeath() = withFailureEvidence {
        phase("launch-after-permission")
        assertTrue(instrumentation.targetContext.packageManager.canRequestPackageInstalls())
        launch()
        screenshot("update-recovery-start")
        // Do not download again: this button must come from verified cache recovery.
        phase("recover-verified-download")
        click("Install update", 90000)
        phase("system-installer")
        assertTrue("Android must show its own installer confirmation", device.wait(Until.hasObject(By.text(Pattern.compile("(?i)INSTALL|UPDATE"))), 30000))
        screenshot("update-installer-confirmation")
        // The host script confirms installation after instrumentation exits, because updating
        // this package terminates its instrumentation process. It then asserts versionCode1209.
    }
}
