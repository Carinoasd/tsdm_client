package kzs.th000.tsdm_client

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.PatternMatcher
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.w3c.dom.Element

/** Real framework filters and Robolectric package resolution, not the former hand-written Device resolver. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 30, 35], manifest = Config.NONE)
@Suppress("DEPRECATION")
class BrowserIntentsTest {
    private val reportUrl = "https://www.tsdm39.com/forum.php?mod=modcp&action=report&fid=49#reports"
    private val httpUrl = "http://example.org/a?x=%E4%B8%AD&y=1#anchor"
    private val pm get() = RuntimeEnvironment.getApplication().packageManager

    private fun webFilter(host: String? = null) = IntentFilter(Intent.ACTION_VIEW).apply {
        addCategory(Intent.CATEGORY_DEFAULT)
        addCategory(Intent.CATEGORY_BROWSABLE)
        addDataScheme("http")
        addDataScheme("https")
        host?.let { addDataAuthority(it, null) }
    }

    private fun install(pkg: String, vararg filters: IntentFilter): ComponentName {
        val component = ComponentName(pkg, "$pkg.Main")
        val shadow = shadowOf(pm)
        shadow.addActivityIfNotPresent(component).apply { exported = true; enabled = true }
        filters.forEach { shadow.addIntentFilterForActivity(component, it) }
        return component
    }

    private fun outgoing(url: String = reportUrl) = BrowserIntents.browserIntent(BrowserIntents.parseWebUri(url)!!)
    // setSelector's Android contract: the selector determines the target; the outer intent is delivered unchanged.
    private fun selected(intent: Intent) = pm.resolveActivity(intent.selector!!, PackageManager.MATCH_DEFAULT_ONLY)
        ?.activityInfo?.let { ComponentName(it.packageName, it.name) }

    @Test fun wildcardBrowserThatAcceptsEveryHostMustRemainUsable() {
        val browser = install("com.oem.browser", webFilter("*"))
        assertEquals(browser, selected(outgoing()))
        assertEquals(browser, selected(outgoing(httpUrl)))
    }

    @Test fun webDefaultWinsOverDownloaderWithAppBrowserCategory() {
        val downloader = install("idm.internet.download.manager", webFilter(), IntentFilter(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_APP_BROWSER)
            addCategory(Intent.CATEGORY_DEFAULT)
        })
        val browser = install("com.oem.browser", webFilter())
        pm.addPreferredActivity(webFilter(), IntentFilter.MATCH_CATEGORY_SCHEME, arrayOf(downloader, browser), browser)
        assertEquals(browser, selected(outgoing()))
        assertEquals(browser, selected(outgoing(httpUrl)))
        val legacySelector = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_APP_BROWSER)
        assertEquals(downloader.packageName, pm.resolveActivity(legacySelector, PackageManager.MATCH_DEFAULT_ONLY)!!.activityInfo.packageName)
    }

    @Test fun downloaderExplicitlyChosenAsWebDefaultIsRespected() {
        val browser = install("com.oem.browser", webFilter())
        val downloader = install("idm.internet.download.manager", webFilter())
        pm.addPreferredActivity(webFilter(), IntentFilter.MATCH_CATEGORY_SCHEME, arrayOf(browser, downloader), downloader)
        assertEquals(downloader, selected(outgoing()))
    }

    @Test fun mainAppBrowserOnlyIsNotAWebHandler() {
        install("idm.internet.download.manager", IntentFilter(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_APP_BROWSER)
            addCategory(Intent.CATEGORY_DEFAULT)
        })
        val browser = install("com.oem.browser", webFilter())
        assertEquals(browser, selected(outgoing()))
    }

    @Test fun noDefaultLeavesAllWebBrowsersEligibleForSystemChoice() {
        val a = install("browser.a", webFilter())
        val b = install("browser.b", webFilter("*"))
        install("forum.clone", webFilter("www.tsdm39.com"))
        val intent = outgoing()
        assertNull(intent.component)
        assertNull(intent.`package`)
        val choices = pm.queryIntentActivities(intent.selector!!, PackageManager.MATCH_DEFAULT_ONLY)
            .map { ComponentName(it.activityInfo.packageName, it.activityInfo.name) }.toSet()
        assertEquals(setOf(a, b), choices)
    }

    @Test fun selectorDoesNotCarryForumHostOrPrivateQuery() {
        val intent = outgoing()
        assertEquals(Intent.ACTION_VIEW, intent.selector!!.action)
        assertTrue(intent.selector!!.hasCategory(Intent.CATEGORY_BROWSABLE))
        assertEquals("https", intent.selector!!.scheme)
        assertNotEquals("www.tsdm39.com", intent.selector!!.data!!.host)
        assertNull(intent.selector!!.data!!.query)
        assertNull(intent.selector!!.data!!.fragment)
    }

    @Test fun originalLinkIsDeliveredUnchangedForBothSchemes() {
        for (url in listOf(reportUrl, httpUrl)) {
            val intent = outgoing(url)
            assertEquals(Intent.ACTION_VIEW, intent.action)
            assertEquals(url, intent.dataString)
            assertTrue(intent.hasCategory(Intent.CATEGORY_BROWSABLE))
            assertEquals(intent.scheme, intent.selector!!.scheme)
            assertNotEquals(0, intent.flags and Intent.FLAG_ACTIVITY_NEW_TASK)
        }
    }

    @Test fun parcelRoundTripPreservesSelectorAndActualUrlSeparately() {
        val parcel = android.os.Parcel.obtain()
        try {
            outgoing().writeToParcel(parcel, 0)
            parcel.setDataPosition(0)
            val restored = Intent.CREATOR.createFromParcel(parcel)
            assertEquals(reportUrl, restored.dataString)
            assertEquals("https://example.com/", restored.selector!!.dataString)
        } finally { parcel.recycle() }
    }

    @Test fun launchDoesNotRequireAnInstalledAppQueryOrResolvedFilter() {
        // This Robolectric PM has no browsers. The app must still ask startActivity: OS visibility may differ.
        assertTrue(pm.queryIntentActivities(outgoing().selector!!, PackageManager.MATCH_DEFAULT_ONLY).isEmpty())
        val attempts = mutableListOf<Intent>()
        assertEquals(BrowserIntents.LaunchResult.STARTED, BrowserIntents.launch(reportUrl) { attempts.add(it) })
        assertEquals(1, attempts.size)
        assertEquals(reportUrl, attempts.single().dataString)
        assertNotNull(attempts.single().selector)
    }

    @Test fun noHandlerIsReportedWithoutUnsafeGenericRetry() {
        var attempts = 0
        val result = BrowserIntents.launch(reportUrl) { attempts++; throw ActivityNotFoundException("private-url") }
        assertEquals(1, attempts)
        assertEquals("BROWSER_NO_HANDLER", result.errorCode)
        assertFalse(result.message!!.contains("private-url"))
    }

    @Test fun systemRefusalIsDistinctAndDoesNotLeakExceptionUrl() {
        var attempts = 0
        val result = BrowserIntents.launch(reportUrl) { attempts++; throw SecurityException("private-url") }
        assertEquals(1, attempts)
        assertEquals("BROWSER_NOT_ALLOWED", result.errorCode)
        assertFalse(result.message!!.contains("private-url"))
    }

    @Test fun invalidInputNeverStartsAnything() {
        for (url in listOf(null, "", " ", "javascript:alert(1)", "file:///tmp/a", "tsdm://x", "https:", "https:///", "123", "Alice", "https://example.com/a b")) {
            assertEquals(BrowserIntents.LaunchResult.INVALID_URL, BrowserIntents.launch(url) { fail("Started $url") })
        }
    }

    @Test fun successfulRequestCanBeRepeatedAfterReturning() {
        val urls = mutableListOf<String?>()
        repeat(2) { assertEquals(BrowserIntents.LaunchResult.STARTED, BrowserIntents.launch(reportUrl) { urls.add(it.dataString) }) }
        assertEquals(listOf(reportUrl, reportUrl), urls)
    }

    private fun Element.elements(tag: String): List<Element> {
        val nodes = getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }
    }

    private fun appFilters(): List<IntentFilter> {
        val root = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File(requireNotNull(System.getProperty("appManifest")))).documentElement
        val activity = root.elements("activity").single { it.getAttribute("android:name") == ".MainActivity" }
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

    @Test fun actualForumManifestAndRepackagedCopiesCannotMatchSelector() {
        val filters = appFilters().toTypedArray()
        val forum = install("com.tsdm.tsdm_client", *filters)
        val clone = install("com.tsdm.repack", *filters)
        val generic = Intent(Intent.ACTION_VIEW, Uri.parse(reportUrl)).addCategory(Intent.CATEGORY_BROWSABLE)
        val candidates = pm.queryIntentActivities(generic, PackageManager.MATCH_DEFAULT_ONLY)
            .map { ComponentName(it.activityInfo.packageName, it.activityInfo.name) }
        assertTrue(candidates.containsAll(listOf(forum, clone)))
        assertTrue(pm.queryIntentActivities(outgoing().selector!!, PackageManager.MATCH_DEFAULT_ONLY).isEmpty())
        val browser = install("com.oem.browser", webFilter("*"))
        assertEquals(browser, selected(outgoing()))
    }
}
