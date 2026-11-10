package kzs.th000.tsdm_client

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import java.io.File
import java.io.IOException

/**
 * The attachments the app downloaded (`attachments` in the app's directory on the shared storage, or in its own files
 * when there is none), handed to the app that opens their type through the update file provider.
 */
object AttachmentFiles {
    private const val FOLDER = "attachments"

    private fun roots(context: Context): List<File> = listOfNotNull(
        context.getExternalFilesDir(null)?.let { File(it, FOLDER) },
        File(context.filesDir, FOLDER),
    )

    /** The file at [path] when it is a file inside one of [roots], null otherwise. */
    internal fun validate(roots: List<File>, path: String): File? {
        val file = try {
            File(path).canonicalFile
        } catch (_: IOException) {
            return null
        }
        if (!file.isFile) return null
        val inside = roots.any { root ->
            val prefix = try {
                root.canonicalFile.path + File.separator
            } catch (_: IOException) {
                return@any false
            }
            file.path.startsWith(prefix)
        }
        return if (inside) file else null
    }

    /**
     * Start the app that views the downloaded file at [path], the system asking which one when several do. False when
     * the path is no download of the app or no app views its type.
     */
    fun open(context: Context, path: String?, start: (Intent) -> Unit): Boolean {
        val file = path?.let { validate(roots(context), it) } ?: return false
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.updates", file)
        val type = MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "*/*"
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, type)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            start(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }
}
