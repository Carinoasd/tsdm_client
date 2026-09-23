package kzs.th000.tsdm_client

import android.content.Intent
import android.net.Uri

/**
 * Intents that open a web link in a browser and never in this app (GitHub #105).
 *
 * MainActivity catches `https://www.tsdm39.com/forum.php...` links (see the VIEW intent filter in the manifest), so a
 * plain ACTION_VIEW for such a link may resolve back to this app instead of a browser.
 */
object BrowserIntents {
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
     * ACTION_VIEW of [uri] resolved among browsers only.
     *
     * The selector replaces this intent when the activity is resolved: only activities declaring
     * ACTION_MAIN + CATEGORY_APP_BROWSER match, so the VIEW filters of this app never do. The chosen browser still
     * receives this intent, ACTION_VIEW with [uri] as data. See
     * https://developer.android.com/reference/android/content/Intent#setSelector(android.content.Intent)
     */
    fun browserOnlyViewIntent(uri: Uri): Intent = Intent(Intent.ACTION_VIEW, uri).apply {
        selector = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_APP_BROWSER)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
}
