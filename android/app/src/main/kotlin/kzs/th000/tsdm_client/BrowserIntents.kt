package kzs.th000.tsdm_client

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri

/** Opens web links using Android's default web handler without enumerating installed applications. */
object BrowserIntents {
    const val STRATEGY = "web-selector-v4"

    enum class LaunchResult(val errorCode: String?, val message: String?) {
        STARTED(null, null),
        INVALID_URL("BROWSER_INVALID_URL", "Only absolute HTTP(S) links can be opened"),
        NO_BROWSER("BROWSER_NO_HANDLER", "Android found no browser for web links"),
        NOT_ALLOWED("BROWSER_NOT_ALLOWED", "Android refused the browser launch"),
    }

    fun parseWebUri(url: String?): Uri? {
        if (url.isNullOrEmpty() || url.any { it.isWhitespace() }) return null
        return try {
            val uri = Uri.parse(url)
            val scheme = uri.scheme?.lowercase()
            if ((scheme != "http" && scheme != "https") || uri.host.isNullOrEmpty()) null else uri
        } catch (e: Exception) {
            null
        }
    }

    /**
     * The selector resolves a general webpage instead of a forum deep link. Android applies its normal web
     * default/chooser rules; the selected activity receives the outer VIEW with the unmodified actual URL.
     * This deliberately uses VIEW+BROWSABLE, not MAIN+APP_BROWSER (which can prefer a downloader over the user's
     * web default). No queryIntentActivities/ResolveInfo.filter preflight: visibility or missing OEM metadata
     * must not prevent startActivity from resolving a working browser. example.com is used only for matching,
     * never loaded. Our forum-only intent filters, including repackaged copies, cannot match this selector.
     * https://developer.android.com/reference/android/content/Intent#setSelector(android.content.Intent)
     */
    fun browserIntent(uri: Uri): Intent = Intent(Intent.ACTION_VIEW, uri).apply {
        addCategory(Intent.CATEGORY_BROWSABLE)
        selector = Intent(Intent.ACTION_VIEW, Uri.parse("${uri.scheme!!.lowercase()}://example.com/"))
            .addCategory(Intent.CATEGORY_BROWSABLE)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    /** One launch attempt; failures are reported to Flutter rather than silently becoming false or a generic VIEW. */
    fun launch(url: String?, startActivity: (Intent) -> Unit): LaunchResult {
        val uri = parseWebUri(url) ?: return LaunchResult.INVALID_URL
        return try {
            startActivity(browserIntent(uri))
            LaunchResult.STARTED
        } catch (e: ActivityNotFoundException) {
            LaunchResult.NO_BROWSER
        } catch (e: SecurityException) {
            LaunchResult.NOT_ALLOWED
        }
    }
}
