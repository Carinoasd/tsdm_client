package kzs.th000.tsdm_client

import android.content.Context
import android.content.Intent
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

    /** The shared content of [intent], or null when it carries nothing this app takes. Does file IO: call off the main thread. */
    fun read(context: Context, intent: Intent): Map<String, Any?>? {
        if (!isShare(intent)) return null
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() }
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)?.takeIf { it.isNotBlank() }
        val images = copyImages(context, streamsOf(intent))
        if (text == null && images.isEmpty()) return null
        return mapOf("subject" to subject, "text" to text, "images" to images)
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
        removeStale(dir)
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

    private fun removeStale(dir: File) {
        val now = System.currentTimeMillis()
        dir.listFiles()?.forEach { if (now - it.lastModified() > STALE_AFTER_MS) it.delete() }
    }
}
