package kzs.th000.tsdm_client

import android.content.Intent
import android.content.IntentFilter
import android.os.PatternMatcher
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.w3c.dom.Element

/** Regression #105: the real manifest accepts report URLs, but browser routing must exclude this app. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
class BrowserIntentsTest {
    private val reportUrl = "https://www.tsdm39.com/forum.php?mod=modcp&action=report&fid=247#reports"

    private fun Element.elements(tag: String): List<Element> {
        val nodes = getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }
    }

    private fun appFilters(): List<IntentFilter> {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File(System.getProperty("appManifest")))
        val activity = document.documentElement.elements("activity")
            .single { it.getAttribute("android:name") == ".MainActivity" }
        return activity.elements("intent-filter").map { node ->
            IntentFilter().apply {
                node.elements("action").forEach { addAction(it.getAttribute("android:name")) }
                node.elements("category").forEach { addCategory(it.getAttribute("android:name")) }
                node.elements("data").forEach {
                    val scheme = it.getAttribute("android:scheme")
                    val host = it.getAttribute("android:host")
                    val prefix = it.getAttribute("android:pathPrefix")
                    if (scheme.isNotEmpty()) addDataScheme(scheme)
                    if (host.isNotEmpty()) addDataAuthority(host, null)
                    if (prefix.isNotEmpty()) addDataPath(prefix, PatternMatcher.PATTERN_PREFIX)
                }
            }
        }
    }

    private fun IntentFilter.accepts(intent: Intent): Boolean =
        match(intent.action, intent.type, intent.scheme, intent.data, intent.categories, "BrowserIntentsTest") >= 0

    @Test fun reportLinkCannotResolveBackToOurManifest() {
        val uri = BrowserIntents.parseWebUri(reportUrl)!!
        val generic = Intent(Intent.ACTION_VIEW, uri)
        val filters = appFilters()
        assertTrue("Without a selector the app is a candidate: the original bug", filters.any { it.accepts(generic) })
        val outgoing = BrowserIntents.browserOnlyViewIntent(uri)
        val resolved = outgoing.selector ?: outgoing
        assertFalse("The browser launch must not match any of our actual activity filters", filters.any { it.accepts(resolved) })
        val browser = IntentFilter(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_APP_BROWSER)
            addCategory(Intent.CATEGORY_DEFAULT)
        }
        assertTrue("A browser remains eligible", browser.accepts(resolved))
    }

    @Test fun selectedBrowserReceivesOriginalLinkAndViewAction() {
        for (url in listOf(reportUrl, "http://example.com/a?x=%E4%B8%AD&y=1#anchor")) {
            val outgoing = BrowserIntents.browserOnlyViewIntent(BrowserIntents.parseWebUri(url)!!)
            assertEquals(Intent.ACTION_VIEW, outgoing.action)
            assertEquals(url, outgoing.dataString)
            assertNull(outgoing.component)
            assertNull(outgoing.`package`)
        }
    }

    @Test fun refusesNonWebOrMissingHostWithoutLaunching() {
        for (url in listOf(null, "", " ", "javascript:alert(1)", "file:///tmp/a", "tsdm://x", "https:", "https:///", "123", "Alice", "https://example.com/a b")) {
            assertNull("Must reject $url", BrowserIntents.parseWebUri(url))
        }
    }
}
