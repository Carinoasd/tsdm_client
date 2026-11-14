package kzs.th000.tsdm_client

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileOutputStream

/**
 * What another app shared to this one (`ACTION_SEND`, `ACTION_SEND_MULTIPLE`), read into the map Dart receives on the
 * `shareReceive` channel: `subject` and `text` (strings or null) and `images` (paths of files in this app's cache).
 *
 * Dart cannot read a `content://` uri, so every shared image is copied into [imageDir] first and only the path is
 * handed over; Dart deletes the file once it uploaded it. Files left there (the app was killed before) are removed
 * once they are a day old. At most [MAX_IMAGES] images are copied, none larger than [MAX_IMAGE_BYTES].
 *
 * Only another app's `content://` uri is read ([acceptsStream]): the copy is made with this app's own rights, so a uri
 * of one of its own providers (or a `file://` one) would hand its private files (attachments, the cookie database) to
 * whoever shared it. [MainActivityImpl] is exported too, so this holds for a share that did not pass [ShareActivity].
 */
object ShareIntents {
    const val CHANNEL = "kzs.th000.tsdm_client/shareReceive"
    const val GET_INITIAL_SHARE = "getInitialShare"
    const val ON_SHARE = "onShare"

    const val MAX_IMAGES = 9
    const val MAX_IMAGE_BYTES = 50L * 1024 * 1024
    private const val STALE_AFTER_MS = 24L * 60 * 60 * 1000

    fun isShare(intent: Intent?): Boolean =
        intent != null && (intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE)

    /**
     * The shared content of [intent], or null when it carries nothing this app takes. Does file IO: call off the main thread.
     * [ownsAuthority] tells this app's provider authorities ([ownsAuthority] of the context unless a test replaces it).
     */
    fun read(
        context: Context,
        intent: Intent,
        ownsAuthority: (String) -> Boolean = { ownsAuthority(context, it) },
    ): Map<String, Any?>? {
        removeStale(imageDir(context))
        if (!isShare(intent)) return null
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() }
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)?.takeIf { it.isNotBlank() }
        val images = copyImages(context, streamsOf(intent).filter { acceptsStream(it, ownsAuthority) })
        if (text == null && images.isEmpty()) return null
        return mapOf("subject" to subject, "text" to text, "images" to images)
    }

    /**
     * Whether a shared [uri] may be read: a `content://` uri of a provider that is not this app's. Decided before any
     * resolver call. The authority is compared the way the resolver finds the provider: without the `<user id>@` prefix
     * it may carry.
     */
    internal fun acceptsStream(uri: Uri, ownsAuthority: (String) -> Boolean): Boolean {
        if (!"content".equals(uri.scheme, ignoreCase = true)) return false
        val authority = providerAuthority(uri) ?: return false
        return try {
            !ownsAuthority(authority)
        } catch (_: Exception) {
            false
        }
    }

    /** The provider authority of [uri] without the user id prefix (`10@authority`), null when it has none. */
    internal fun providerAuthority(uri: Uri): String? =
        uri.authority?.substringAfterLast('@')?.takeIf { it.isNotEmpty() }

    /**
     * Whether [authority] is one of this app's providers: its own ones and the ones its libraries declare (FileProviders
     * of image_picker, share_plus, androidx startup), or one named under its package. Compared ignoring case. When the
     * package cannot be read the answer is yes: the share then goes without its images.
     */
    fun ownsAuthority(context: Context, authority: String): Boolean {
        val packageName = context.packageName
        if (authority.startsWith("$packageName.", ignoreCase = true) || authority.equals(packageName, ignoreCase = true)) {
            return true
        }
        return try {
            val pm = context.packageManager
            @Suppress("DEPRECATION")
            val declared = pm.getPackageInfo(packageName, PackageManager.GET_PROVIDERS).providers.orEmpty()
            declared.any { provider -> provider.authority.orEmpty().split(';').any { it.trim().equals(authority, ignoreCase = true) } } ||
                pm.resolveContentProvider(authority, 0)?.packageName == packageName
        } catch (_: Exception) {
            true
        }
    }

    private fun streamsOf(intent: Intent): List<Uri> {
        val uris = ArrayList<Uri>()
        try {
            if (intent.action == Intent.ACTION_SEND) {
                single(intent)?.let { uris.add(it) }
            } else {
                multiple(intent)?.let { uris.addAll(it.filterNotNull()) }
            }
        } catch (_: Exception) {
            // A malformed extra from another app: shared as if it carried no image.
        }
        return uris
    }

    @Suppress("DEPRECATION")
    private fun single(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    @Suppress("DEPRECATION")
    private fun multiple(intent: Intent): List<Uri?>? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
        }

    private fun imageDir(context: Context): File = File(context.cacheDir, "shared_images")

    /** Copy the image [uris] into the cache, in order; a uri that is not an image, unreadable or too large is skipped. */
    private fun copyImages(context: Context, uris: List<Uri>): List<String> {
        if (uris.isEmpty()) return emptyList()
        val dir = imageDir(context)
        dir.mkdirs()
        val resolver = context.contentResolver
        val paths = ArrayList<String>()
        val stamp = System.currentTimeMillis()
        for ((index, uri) in uris.take(MAX_IMAGES).withIndex()) {
            val mime = try { resolver.getType(uri) } catch (_: Exception) { null } ?: ""
            if (!mime.startsWith("image/")) continue
            val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: "jpg"
            val file = File(dir, "${stamp}_$index.$ext")
            if (copy(resolver, uri, file)) paths.add(file.absolutePath) else file.delete()
        }
        return paths
    }

    private fun copy(resolver: android.content.ContentResolver, uri: Uri, file: File): Boolean {
        return try {
            resolver.openInputStream(uri)?.use { input ->
                FileOutputStream(file).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > MAX_IMAGE_BYTES) return false
                        output.write(buffer, 0, count)
                    }
                    total > 0
                }
            } ?: false
        } catch (_: Exception) {
            false
        }
    }

    /** Delete copies a day old: Dart deletes a copy once it uploaded it, but the app may have been killed before. */
    fun removeStale(dir: File) {
        val now = System.currentTimeMillis()
        dir.listFiles()?.forEach { if (now - it.lastModified() > STALE_AFTER_MS) it.delete() }
    }

    /** [removeStale] of this app's shared image copies; file IO. */
    fun removeStale(context: Context) = removeStale(imageDir(context))
}
