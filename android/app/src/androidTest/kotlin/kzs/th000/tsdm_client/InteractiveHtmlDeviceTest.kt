package kzs.th000.tsdm_client

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.test.espresso.web.sugar.Web.onWebView
import androidx.test.espresso.web.webdriver.DriverAtoms.*
import androidx.test.espresso.web.webdriver.Locator
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Runs in a real Android WebView; the reduced fixture uses the forum's actual inline form handler. */
@RunWith(AndroidJUnit4::class)
class InteractiveHtmlDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(instrumentation)
    private var activity: Activity? = null
    private val source = "https://www.tsdm39.com/forum.php?mod=viewthread&tid=1266801"
    private var phase = "start"
    private val resetMessage = By.res("android:id/message").text("确定清空所有草稿？")

    private fun phase(name: String) {
        phase = name
        Log.i("InteractiveHtmlTest", "Starting $name")
    }

    private fun open(scope: String, post: String = "78060680") {
        activity?.let { old -> instrumentation.runOnMainSync { old.finish() } }
        instrumentation.waitForIdleSync()
        val html = instrumentation.context.assets.open("fes_interactive_fixture.html").bufferedReader().use { it.readText() }
        val intent = InteractiveHtmlActivity.intent(instrumentation.targetContext, html, source, scope, post)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        activity = instrumentation.startActivitySync(intent)
        instrumentation.waitForIdleSync()
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(25)
        while (System.nanoTime() < deadline) {
            if (js("!!document.getElementById('tfOpen')") == "true") return
            Thread.sleep(100)
        }
        fail("Interactive HTML did not load in Android WebView")
    }

    private fun webView(view: View): WebView? {
        if (view is WebView) return view
        if (view is ViewGroup) for (i in 0 until view.childCount) webView(view.getChildAt(i))?.let { return it }
        return null
    }

    private fun js(expression: String): String {
        val done = CountDownLatch(1)
        var answer = "null"
        instrumentation.runOnMainSync {
            val current = checkNotNull(activity) { "No viewer activity during $phase" }
            val web = webView(current.window.decorView)
            checkNotNull(web) {
                "No production WebView during $phase (activity=$current, destroyed=${current.isDestroyed}, finishing=${current.isFinishing})"
            }
            web.evaluateJavascript(expression) { answer = it; done.countDown() }
        }
        check(done.await(10, TimeUnit.SECONDS)) { "WebView JS read timed out" }
        return answer
    }

    private fun click(id: String) {
        onWebView().withElement(findElement(Locator.ID, id)).perform(webScrollIntoView()).perform(webClick())
    }

    private fun type(id: String, value: String) {
        onWebView().withElement(findElement(Locator.ID, id)).perform(webScrollIntoView()).perform(webKeys(value))
    }

    private fun clickReset() {
        onWebView().withElement(findElement(Locator.ID, "reset")).perform(webScrollIntoView())
        // A WebDriver JS click waits for window.confirm to return, preventing
        // this test from reaching the native dialog controls that resolve it.
        checkNotNull(device.wait(Until.findObject(By.text("清空草稿")), 5000)) {
            "Visible reset button"
        }.click()
        // Input injection returns before WebView dispatches the handler and
        // onJsConfirm shows its native dialog. Back before this point can close
        // the entire activity instead of cancelling the draft reset.
        checkNotNull(device.wait(Until.findObject(resetMessage), 10000)) {
            "JavaScript reset confirmation must be visible during $phase"
        }
        assertTrue(device.wait(Until.hasObject(By.res("android:id/button1")), 5000))
    }

    private fun waitForResetDismissal() {
        assertTrue("Reset confirmation must dismiss during $phase", device.wait(Until.gone(resetMessage), 5000))
        instrumentation.waitForIdleSync()
    }

    private fun screenshot(name: String) {
        EmulatorEvidence.capture(device, name, hierarchy = true)
    }

    private fun refreshActivityAfterRotation() {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (System.nanoTime() < deadline) {
            var resumed: Activity? = null
            instrumentation.runOnMainSync {
                resumed = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                    .filterIsInstance<InteractiveHtmlActivity>().singleOrNull()
            }
            if (resumed != null) { activity = resumed; return }
            Thread.sleep(100)
        }
        fail("Viewer did not resume after rotation")
    }

    @Test fun liveWebViewFormCopyDraftIsolationAndRotation() {
        try {
            phase("initial-interactions")
            open("emulator-alice")
            click("cheer")
            assertEquals("\"1\"", js("document.getElementById('tfCheer').textContent"))
            click("pause")
            assertEquals("true", js("document.getElementById('tfVinyl').classList.contains('paused')"))
            screenshot("html-portrait")
            phase("form-and-generation")
            click("tfOpen")
            type("fSeSong", "Offline emulator song")
            type("fSeMod", "@fixture")
            type("fSeMsg", "No forum submission")
            assertEquals("\"1\"", js("document.getElementById('tfEst').textContent"))
            click("answerA")
            click("time10")
            click("generate")
            assertEquals("true", js("document.getElementById('tfOut').value.includes('[hide=9999999]')"))
            assertEquals("true", js("document.getElementById('tfOut').value.includes('Offline emulator song')"))
            phase("clipboard")
            onWebView().withElement(findElement(Locator.ID, "copy")).perform(webScrollIntoView())
            // Clipboard writes require a real user gesture, not a synthetic WebDriver DOM click.
            val copy = checkNotNull(device.wait(Until.findObject(By.text("复制文字")), 5000)) { "Visible copy button" }
            copy.click()
            device.waitForIdle()
            assertEquals("\"已复制 ✓\"", js("document.getElementById('copy').textContent"))
            instrumentation.runOnMainSync {
                val clipboard = instrumentation.targetContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                assertTrue(clipboard.primaryClip!!.getItemAt(0).coerceToText(instrumentation.targetContext).contains("Offline emulator song"))
            }
            screenshot("html-generated-and-copied")
            phase("landscape")
            device.setOrientationLeft()
            device.waitForIdle()
            refreshActivityAfterRotation()
            screenshot("html-landscape")
            phase("portrait")
            device.setOrientationNatural()
            device.waitForIdle()
            refreshActivityAfterRotation()
            phase("persisted-draft")
            open("emulator-alice")
            click("tfOpen")
            assertEquals("\"Offline emulator song\"", js("document.getElementById('fSeSong').value"))
            phase("account-isolation")
            open("emulator-bob")
            click("tfOpen")
            assertEquals("\"\"", js("document.getElementById('fSeSong').value"))
            phase("post-isolation")
            open("emulator-alice", "78060681")
            click("tfOpen")
            assertEquals("\"\"", js("document.getElementById('fSeSong').value"))
            phase("cancel-reset")
            open("emulator-alice")
            click("tfOpen")
            clickReset()
            screenshot("html-reset-confirmation")
            device.pressBack()
            waitForResetDismissal()
            assertEquals("\"Offline emulator song\"", js("document.getElementById('fSeSong').value"))
            phase("confirm-reset")
            clickReset()
            val confirm = checkNotNull(device.findObject(By.res("android:id/button1"))) { "Native confirmation button" }
            confirm.click()
            waitForResetDismissal()
            assertEquals("\"\"", js("document.getElementById('fSeSong').value"))
            screenshot("html-reset-complete")
        } catch (failure: Throwable) {
            Log.e("InteractiveHtmlTest", "Failed during $phase", failure)
            try {
                screenshot("html-failure-$phase")
            } catch (diagnosticFailure: Exception) {
                failure.addSuppressed(diagnosticFailure)
            }
            throw failure
        } finally {
            device.unfreezeRotation()
            activity?.let { old -> instrumentation.runOnMainSync { old.finish() } }
        }
    }
}
