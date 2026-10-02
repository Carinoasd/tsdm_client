package kzs.th000.tsdm_client

import android.content.Intent
import android.net.Uri
import android.view.View
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.w3c.dom.Element

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
class InteractiveHtmlActivityTest {
    private val source = "https://www.tsdm39.com/forum.php?mod=viewthread&tid=1266801"
    private val html = "<button onclick=\"this.textContent='Done'\">Run</button>"
    private fun launchIntent() = InteractiveHtmlActivity.intent(RuntimeEnvironment.getApplication(), html, source, "guest", "42")
    private fun request(raw: String, main: Boolean = true, gesture: Boolean = false, method: String = "GET") = object : WebResourceRequest {
        override fun getUrl() = Uri.parse(raw)
        override fun isForMainFrame() = main
        override fun isRedirect() = false
        override fun hasGesture() = gesture
        override fun getMethod() = method
        override fun getRequestHeaders() = mutableMapOf<String, String>()
    }
    private fun viewer(activity: InteractiveHtmlActivity): WebView = activity.findViewById<View>(android.R.id.content)
        .findViewWithTag("interactive_html_webview")

    @Test fun intentCarriesOnlyValidatedFragmentContextAndTargetsUnexportedViewer() {
        val intent = launchIntent()
        assertEquals(InteractiveHtmlActivity::class.java.name, intent.component!!.className)
        assertEquals(html, intent.getStringExtra(InteractiveHtmlActivity.EXTRA_HTML))
        assertEquals(source, intent.getStringExtra(InteractiveHtmlActivity.EXTRA_SOURCE_URL))
        assertEquals("guest", intent.getStringExtra(InteractiveHtmlActivity.EXTRA_ACCOUNT_SCOPE))
        assertEquals("42", intent.getStringExtra(InteractiveHtmlActivity.EXTRA_POST_ID))
        assertNull(intent.data)
        val root = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File(requireNotNull(System.getProperty("appManifest")))).documentElement
        val activities = root.getElementsByTagName("activity")
        val activity = (0 until activities.length).map { activities.item(it) as Element }
            .single { it.getAttribute("android:name") == InteractiveHtmlActivity::class.java.name }
        assertEquals("false", activity.getAttribute("android:exported"))
    }

    @Test fun viewerEnablesDomStorageWhileKeepingNativeFilesAndNetworkClosed() {
        val controller = Robolectric.buildActivity(InteractiveHtmlActivity::class.java, launchIntent()).setup()
        val view = viewer(controller.get())
        assertTrue(view.settings.javaScriptEnabled)
        assertTrue(view.settings.domStorageEnabled)
        assertFalse(view.settings.allowFileAccess)
        assertFalse(view.settings.allowContentAccess)
        assertFalse(view.settings.javaScriptCanOpenWindowsAutomatically)
        assertTrue(view.settings.blockNetworkLoads)
        assertEquals(WebSettings.MIXED_CONTENT_NEVER_ALLOW, view.settings.mixedContentMode)
        assertTrue(shadowOf(view).lastLoadedUrl.contains(".interactive.tsdm.invalid/"))
        controller.pause().stop().destroy()
        assertTrue(shadowOf(view).wasOnPauseCalled())
        assertTrue(shadowOf(view).wasDestroyCalled())
        assertFalse(shadowOf(view).wasClearCacheCalled())
    }

    @Test fun onlyTheSyntheticMainDocumentGetsHtmlAndSecurityHeaders() {
        val controller = Robolectric.buildActivity(InteractiveHtmlActivity::class.java, launchIntent()).setup()
        val view = viewer(controller.get())
        val documentUrl = shadowOf(view).lastLoadedUrl
        val response = view.webViewClient.shouldInterceptRequest(view, request(documentUrl))!!
        assertEquals("text/html", response.mimeType)
        assertTrue(response.responseHeaders.getValue("Content-Security-Policy").contains("connect-src 'none'"))
        assertTrue(response.data.bufferedReader().readText().contains(html))
        for (candidate in listOf(request(source), request(documentUrl, main = false), request(documentUrl, method = "POST"),
            request("https://example.com/payload.js", main = false))) {
            assertEquals(403, view.webViewClient.shouldInterceptRequest(view, candidate)!!.statusCode)
        }
        controller.pause().stop().destroy()
    }

    @Test fun navigationRequiresAUserGestureAndForumLinksReturnToMainActivity() {
        val controller = Robolectric.buildActivity(InteractiveHtmlActivity::class.java, launchIntent()).setup()
        val activity = controller.get()
        val view = viewer(activity)
        val client = view.webViewClient
        assertTrue(client.shouldOverrideUrlLoading(view, request("https://example.com/")))
        assertTrue(client.shouldOverrideUrlLoading(view, request("javascript:alert(1)", gesture = true)))
        assertTrue(client.shouldOverrideUrlLoading(view, request("file:///tmp/x", gesture = true)))
        assertNull(shadowOf(activity).nextStartedActivity)
        assertTrue(client.shouldOverrideUrlLoading(view, request("https://example.com/help", gesture = true)))
        val external = shadowOf(activity).nextStartedActivity
        assertEquals("https://example.com/help", external.dataString)
        assertNotNull(external.selector)
        assertTrue(client.shouldOverrideUrlLoading(view, request(source, gesture = true)))
        val forum = shadowOf(activity).nextStartedActivity
        assertEquals(Intent.ACTION_VIEW, forum.action)
        assertEquals("kzs.th000.tsdm_client.MainActivity", forum.component!!.className)
        assertEquals(source, forum.dataString)
        controller.pause().stop().destroy()
    }
}
