package kzs.th000.tsdm_client

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.net.Uri

/**
 * Intents that open a web link in a browser and never in this app (GitHub #105).
 *
 * MainActivity catches `https://www.tsdm39.com/forum.php...` links (see the VIEW intent filter in the manifest), so a
 * plain ACTION_VIEW for such a link may resolve back to this app instead of a browser.
 *
 * The browser is looked up with [browserProbe], a VIEW + BROWSABLE intent of a neutral page, and only apps whose
 * matching filter handles every host of the scheme count. Apps that only handle some domains (this app, other
 * builds of it) never do. The user's default browser gets the link when the system reports one, otherwise the user
 * picks among the browsers. The link is then sent to that browser explicitly, so no app link can take it over.
 *
 * The earlier MAIN + CATEGORY_APP_BROWSER selector ignored the default browser: many preinstalled browsers do not
 * declare that category while some download managers do, and the first of those was opened.
 */
object BrowserIntents {
    /** The package manager lookups used here; see [PackageManagerResolver]. */
    interface Resolver {
        /** The activity [probe] resolves to by default: a browser, the system resolver, or null. */
        fun defaultActivity(probe: Intent): ResolveInfo?

        /** All activities handling [probe], with the filter each one matched. */
        fun activities(probe: Intent): List<ResolveInfo>
    }

    @Suppress("DEPRECATION")
    class PackageManagerResolver(private val packageManager: PackageManager) : Resolver {
        /** Without a default the system returns its resolver activity, which is never among [activities]. */
        override fun defaultActivity(probe: Intent): ResolveInfo? =
            packageManager.resolveActivity(probe, PackageManager.MATCH_DEFAULT_ONLY)

        override fun activities(probe: Intent): List<ResolveInfo> =
            packageManager.queryIntentActivities(
                probe,
                PackageManager.MATCH_DEFAULT_ONLY or PackageManager.GET_RESOLVED_FILTER,
            )
    }

    /**
     * The link in [url] as an absolute `http` or `https` uri with a host, or null when it is anything else.
     *
     * The uri is built from the string as is, so its query and fragment reach the browser exactly as sent.
     */
    fun parseWebUri(url: String?): Uri? {
        if (url.isNullOrEmpty() || url.any { it.isWhitespace() }) {
            return null
        }
        return try {
            val uri = Uri.parse(url)
            val scheme = uri.scheme?.lowercase()
            if ((scheme != "http" && scheme != "https") || uri.host.isNullOrEmpty()) null else uri
        } catch (e: Exception) {
            null
        }
    }

    /**
     * VIEW + BROWSABLE of a neutral page with the scheme of [uri], never of [uri] itself: what any browser handles
     * and no forum app does. `example.com` is reserved (RFC 2606), so no app is expected to claim it.
     */
    fun browserProbe(uri: Uri): Intent =
        Intent(Intent.ACTION_VIEW, Uri.parse("${uri.scheme!!.lowercase()}://example.com/"))
            .addCategory(Intent.CATEGORY_BROWSABLE)

    /**
     * The intent opening [uri] in a browser, or null when there is no browser.
     *
     * The default browser when the system reports one, the only browser when there is one, otherwise a chooser
     * listing the browsers only. Activities of [selfPackage] are never used.
     */
    fun browserIntent(uri: Uri, resolver: Resolver, selfPackage: String): Intent? {
        val probe = browserProbe(uri)
        val browsers = resolver.activities(probe)
            .filter { isBrowser(it, probe.scheme!!, selfPackage) }
            .mapNotNull(::componentOf)
            .distinct()
        if (browsers.isEmpty()) {
            return null
        }
        val defaultComponent = resolver.defaultActivity(probe)?.let(::componentOf)
        val chosen = browsers.firstOrNull { it == defaultComponent } ?: browsers.singleOrNull()
        if (chosen != null) {
            return viewIntent(uri, chosen)
        }
        val targets = browsers.map { viewIntent(uri, it) }
        return Intent.createChooser(targets.first(), null).apply {
            putExtra(Intent.EXTRA_INITIAL_INTENTS, targets.drop(1).toTypedArray())
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
    }

    /**
     * Whether [info] is an exported, enabled activity of another app handling every link of [scheme].
     *
     * The filter comes from GET_RESOLVED_FILTER. A missing or host-restricted filter cannot establish that the
     * activity handles general web links, so it is refused rather than guessing from its package name.
     */
    private fun isBrowser(info: ResolveInfo, scheme: String, selfPackage: String): Boolean {
        val activity = info.activityInfo ?: return false
        if (activity.packageName == selfPackage || !activity.exported || !activity.isEnabled) {
            return false
        }
        val filter = info.filter ?: return false
        return filter.hasDataScheme(scheme) && filter.countDataAuthorities() == 0
    }

    private fun componentOf(info: ResolveInfo): ComponentName? =
        info.activityInfo?.let { ComponentName(it.packageName, it.name) }

    /** ACTION_VIEW of [uri] for [component] only, [uri] unchanged. */
    private fun viewIntent(uri: Uri, component: ComponentName): Intent = Intent(Intent.ACTION_VIEW, uri).apply {
        addCategory(Intent.CATEGORY_BROWSABLE)
        this.component = component
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
}
