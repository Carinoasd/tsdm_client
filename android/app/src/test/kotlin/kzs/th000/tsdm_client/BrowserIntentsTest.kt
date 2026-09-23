package kzs.th000.tsdm_client

import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.pm.ApplicationInfo
import android.content.pm.ResolveInfo
import android.os.PatternMatcher
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.w3c.dom.Element

/**
 * Regression #105: links open in the user's default browser, never in this app or another forum app, and never in
 * whatever app happens to declare CATEGORY_APP_BROWSER first.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
class BrowserIntentsTest {
    private val reportUrl = "https://www.tsdm39.com/forum.php?mod=modcp&action=report&fid=247#reports"
    private val httpUrl = "http://example.com/a?x=%E4%B8%AD&y=1#anchor"
    private val self = "com.tsdm.tsdm_client"

    /**
     * A device modelled after the package manager: queries match the installed filters with [IntentFilter.match],
     * MATCH_DEFAULT_ONLY needs CATEGORY_DEFAULT, and resolving several matches without a default returns the
     * system resolver activity. Unlike the real package manager it also reports non-exported or disabled
     * activities, so the checks of the app are exercised.
     */
    private class Device(private val preferred: ComponentName? = null) : BrowserIntents.Resolver {
        private val installed = mutableListOf<ResolveInfo>()
        val resolver = ComponentName("android", "com.android.internal.app.ResolverActivity")

        fun install(
            pkg: String,
            vararg filters: IntentFilter,
            exported: Boolean = true,
            enabled: Boolean = true,
        ): ComponentName {
            val component = ComponentName(pkg, "$pkg.Main")
            filters.forEach { installed.add(resolveInfo(component, it, exported, enabled)) }
            return component
        }

        private fun matching(probe: Intent) = installed.filter {
            it.filter.hasCategory(Intent.CATEGORY_DEFAULT) &&
                it.filter.match(probe.action, probe.type, probe.scheme, probe.data, probe.categories, "Device") >= 0
        }

        override fun activities(probe: Intent): List<ResolveInfo> = matching(probe)

        override fun defaultActivity(probe: Intent): ResolveInfo? {
            val found = matching(probe).distinctBy { it.activityInfo.packageName to it.activityInfo.name }
            return when {
                found.isEmpty() -> null
                found.size == 1 -> found.single()
                else -> found.firstOrNull { ComponentName(it.activityInfo.packageName, it.activityInfo.name) == preferred }
                    ?: resolveInfo(resolver, null, exported = true, enabled = true)
            }
        }

        private fun resolveInfo(component: ComponentName, filter: IntentFilter?, exported: Boolean, enabled: Boolean) =
            ResolveInfo().apply {
                activityInfo = ActivityInfo().apply {
                    packageName = component.packageName
                    name = component.className
                    this.exported = exported
                    this.enabled = enabled
                    applicationInfo = ApplicationInfo().apply { packageName = component.packageName }
                }
                this.filter = filter
            }
    }

    private fun webFilter(vararg schemes: String, host: String? = null, path: String? = null) =
        IntentFilter(Intent.ACTION_VIEW).apply {
            addCategory(Intent.CATEGORY_DEFAULT)
            addCategory(Intent.CATEGORY_BROWSABLE)
            schemes.forEach(::addDataScheme)
            host?.let { addDataAuthority(it, null) }
            path?.let { addDataPath(it, PatternMatcher.PATTERN_PREFIX) }
        }

    private fun appBrowserFilter() = IntentFilter(Intent.ACTION_MAIN).apply {
        addCategory(Intent.CATEGORY_APP_BROWSER)
        addCategory(Intent.CATEGORY_DEFAULT)
    }

    /** The OEM browser: handles web links but does not declare CATEGORY_APP_BROWSER. */
    private fun Device.oemBrowser() = install("com.oem.browser", webFilter("http", "https"))

    /** The download manager of the report: declares CATEGORY_APP_BROWSER and handles web links as well. */
    private fun Device.downloader() = install("idm.internet.download.manager", appBrowserFilter(), webFilter("http", "https"))

    private fun open(url: String, device: Device): Intent? =
        BrowserIntents.browserIntent(BrowserIntents.parseWebUri(url)!!, device, self)

    private fun assertOpensIn(component: ComponentName, url: String, intent: Intent?) {
        assertNotNull(intent)
        assertEquals(component, intent!!.component)
        assertEquals(Intent.ACTION_VIEW, intent.action)
        assertEquals("Query and fragment must reach the browser unchanged", url, intent.dataString)
        assertNull(intent.selector)
    }

    @Suppress("DEPRECATION")
    private fun chooserTargets(intent: Intent?): List<Intent> {
        assertNotNull(intent)
        assertEquals(Intent.ACTION_CHOOSER, intent!!.action)
        val first = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)!!
        val rest = intent.getParcelableArrayExtra(Intent.EXTRA_INITIAL_INTENTS).orEmpty().map { it as Intent }
        return listOf(first) + rest
    }

    @Test fun defaultOemBrowserWinsOverAppBrowserDownloaderInAnyOrder() {
        for (downloaderFirst in listOf(true, false)) {
            val device = Device(preferred = ComponentName("com.oem.browser", "com.oem.browser.Main"))
            val oem: ComponentName
            if (downloaderFirst) {
                device.downloader()
                oem = device.oemBrowser()
            } else {
                oem = device.oemBrowser()
                device.downloader()
            }
            for (url in listOf(reportUrl, httpUrl)) {
                assertOpensIn(oem, url, open(url, device))
            }
        }
    }

    @Test fun legacySelectorReproducesDownloaderBugDespiteOemDefault() {
        val device = Device(preferred = ComponentName("com.oem.browser", "com.oem.browser.Main"))
        val oem = device.oemBrowser()
        val downloader = device.downloader()
        val legacy = Intent(Intent.ACTION_VIEW, BrowserIntents.parseWebUri(reportUrl)).apply {
            selector = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_APP_BROWSER)
        }
        val wrong = device.defaultActivity(legacy.selector!!)!!.activityInfo
        assertEquals(downloader, ComponentName(wrong.packageName, wrong.name))
        assertNotEquals(oem, ComponentName(wrong.packageName, wrong.name))
        assertOpensIn(oem, reportUrl, open(reportUrl, device))
    }

    @Test fun missingFilterDoesNotProveThatAnAppIsABrowser() {
        val unknown = ResolveInfo().apply {
            activityInfo = ActivityInfo().apply {
                packageName = "com.unknown.app"
                name = "com.unknown.app.Main"
                exported = true
                applicationInfo = ApplicationInfo()
            }
        }
        val resolver = object : BrowserIntents.Resolver {
            override fun activities(probe: Intent) = listOf(unknown)
            override fun defaultActivity(probe: Intent) = unknown
        }
        assertNull(BrowserIntents.browserIntent(BrowserIntents.parseWebUri(reportUrl)!!, resolver, self))
    }

    @Test fun downloaderChosenAsDefaultBrowserIsRespected() {
        val device = Device(preferred = ComponentName("idm.internet.download.manager", "idm.internet.download.manager.Main"))
        device.oemBrowser()
        val downloader = device.downloader()
        assertOpensIn(downloader, reportUrl, open(reportUrl, device))
    }

    @Test fun appBrowserCategoryAloneDoesNotMakeABrowser() {
        val device = Device()
        device.install("idm.internet.download.manager", appBrowserFilter())
        val oem = device.oemBrowser()
        assertOpensIn(oem, reportUrl, open(reportUrl, device))
    }

    @Test fun withoutDefaultTheUserChoosesAmongBrowsersOnly() {
        val device = Device()
        val oem = device.oemBrowser()
        val other = device.install("org.other.browser", webFilter("https"), webFilter("http"))
        device.install("tsdm.original", webFilter("https", host = "www.tsdm39.com", path = "/forum.php"))
        val intent = open(reportUrl, device)
        val targets = chooserTargets(intent)
        assertEquals(setOf(oem, other), targets.map { it.component }.toSet())
        assertEquals(2, targets.size)
        for (target in targets) {
            assertEquals(Intent.ACTION_VIEW, target.action)
            assertEquals(reportUrl, target.dataString)
        }
        assertFalse("The system resolver is not a browser", targets.any { it.component == device.resolver })
    }

    @Test fun onlyBrowserIsUsedWithoutAsking() {
        val device = Device()
        val oem = device.oemBrowser()
        assertOpensIn(oem, httpUrl, open(httpUrl, device))
    }

    @Test fun noBrowserGivesNoIntent() {
        val device = Device()
        device.install("idm.internet.download.manager", appBrowserFilter())
        device.install("tsdm.original", webFilter("https", host = "www.tsdm39.com", path = "/forum.php"))
        assertNull(open(reportUrl, device))
    }

    @Test fun neverThisAppNorAnotherForumApp() {
        val device = Device(preferred = ComponentName(self, "$self.Main"))
        // Even if this app handled every link, and was the default, it is skipped.
        device.install(self, webFilter("http", "https"))
        device.install("tsdm.original", webFilter("https", host = "www.tsdm39.com", path = "/forum.php"))
        device.install("tsdm.repack", webFilter("https", host = "tsdm39.com", path = "/forum.php"))
        val oem = device.oemBrowser()
        assertOpensIn(oem, reportUrl, open(reportUrl, device))
    }

    @Test fun domainRestrictedFilterIsRefusedEvenIfReported() {
        val forumApp = ComponentName("tsdm.original", "tsdm.original.Main")
        val reportsForumApp = object : BrowserIntents.Resolver {
            override fun activities(probe: Intent) = listOf(
                ResolveInfo().apply {
                    activityInfo = ActivityInfo().apply {
                        packageName = forumApp.packageName
                        name = forumApp.className
                        exported = true
                        applicationInfo = ApplicationInfo().apply { packageName = forumApp.packageName }
                    }
                    filter = webFilter("https", host = "www.tsdm39.com")
                },
            )

            override fun defaultActivity(probe: Intent) = activities(probe).single()
        }
        assertNull(BrowserIntents.browserIntent(BrowserIntents.parseWebUri(reportUrl)!!, reportsForumApp, self))
    }

    @Test fun nonExportedOrDisabledBrowsersAreSkippedEvenAsDefault() {
        for (flags in listOf(false to true, true to false)) {
            val device = Device(preferred = ComponentName("com.hidden.browser", "com.hidden.browser.Main"))
            device.install("com.hidden.browser", webFilter("http", "https"), exported = flags.first, enabled = flags.second)
            val oem = device.oemBrowser()
            assertOpensIn(oem, reportUrl, open(reportUrl, device))
        }
    }

    @Test fun httpLinkNeedsAnHttpBrowser() {
        val device = Device()
        device.install("com.https.only", webFilter("https"))
        val both = device.oemBrowser()
        assertOpensIn(both, httpUrl, open(httpUrl, device))
    }

    @Test fun productionLookupOnDeviceWithoutBrowsers() {
        val context = RuntimeEnvironment.getApplication()
        val resolver = BrowserIntents.PackageManagerResolver(context.packageManager)
        assertNull(BrowserIntents.browserIntent(BrowserIntents.parseWebUri(reportUrl)!!, resolver, context.packageName))
    }

    @Test fun refusesNonWebOrMissingHostWithoutLaunching() {
        for (url in listOf(null, "", " ", "javascript:alert(1)", "file:///tmp/a", "tsdm://x", "https:", "https:///", "123", "Alice", "https://example.com/a b")) {
            assertNull("Must reject $url", BrowserIntents.parseWebUri(url))
        }
    }

    private fun Element.elements(tag: String): List<Element> {
        val nodes = getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }
    }

    private fun manifest() = DocumentBuilderFactory.newInstance().newDocumentBuilder()
        .parse(File(System.getProperty("appManifest"))).documentElement

    private fun appFilters(): List<IntentFilter> {
        val activity = manifest().elements("activity").single { it.getAttribute("android:name") == ".MainActivity" }
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

    @Test fun ourManifestCatchesReportLinkButNeverTheBrowserProbe() {
        val uri = BrowserIntents.parseWebUri(reportUrl)!!
        val filters = appFilters()
        assertTrue(
            "A plain VIEW of the link may open this app: the original bug",
            filters.any { it.accepts(Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE)) },
        )
        val probe = BrowserIntents.browserProbe(uri)
        assertFalse("This app must never be a browser candidate", filters.any { it.accepts(probe) })
        assertTrue("A browser matches the probe", webFilter("http", "https").accepts(probe))
    }

    @Test fun manifestCanSeeBrowsersOnAndroid11() {
        val intents = manifest().elements("queries").flatMap { it.elements("intent") }
        for (scheme in listOf("http", "https")) {
            assertTrue("<queries> must declare VIEW + BROWSABLE $scheme", intents.any { intent ->
                intent.elements("action").any { it.getAttribute("android:name") == Intent.ACTION_VIEW } &&
                    intent.elements("category").any { it.getAttribute("android:name") == Intent.CATEGORY_BROWSABLE } &&
                    intent.elements("data").any { it.getAttribute("android:scheme") == scheme && !it.hasAttribute("android:host") }
            })
        }
    }
}
