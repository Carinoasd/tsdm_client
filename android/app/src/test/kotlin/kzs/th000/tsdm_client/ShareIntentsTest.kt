package kzs.th000.tsdm_client

import android.content.ComponentName
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import java.io.ByteArrayInputStream
import java.io.File
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** A gallery-like provider: every uri is a small PNG. */
class SharedImageProvider : ContentProvider() {
    override fun onCreate() = true
    override fun getType(uri: Uri) = "image/png"
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, sort: String?): Cursor? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, args: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?) = 0
}

/**
 * A share must not make the app read its own files: the copy of a shared image is made with the app's rights, and
 * [MainActivityImpl] (exported) takes `ACTION_SEND` without passing [ShareActivity].
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
class ShareIntentsTest {
    private val app get() = RuntimeEnvironment.getApplication()
    private val own get() = "${app.packageName}.attachments"
    private val foreign = "com.example.gallery.files"
    private val png = byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 1, 2, 3, 4)

    /** Register [authority] as a provider of images and its [uri] as readable, the way an app's file would be. */
    private fun readable(authority: String, path: String = "a.png"): Uri {
        Robolectric.buildContentProvider(SharedImageProvider::class.java).create(authority)
        val uri = Uri.parse("content://$authority/$path")
        shadowOf(app.contentResolver).registerInputStream(uri, ByteArrayInputStream(png))
        return uri
    }

    private fun send(uri: Uri) = Intent(Intent.ACTION_SEND).setType("image/png").putExtra(Intent.EXTRA_STREAM, uri)

    @Suppress("UNCHECKED_CAST")
    private fun images(result: Map<String, Any?>?) = (result?.get("images") as List<String>?).orEmpty()

    @Test fun onlyAnotherAppsContentUriIsAccepted() {
        val ours = { authority: String -> authority.equals(own, ignoreCase = true) }
        assertTrue(ShareIntents.acceptsStream(Uri.parse("content://$foreign/a.png"), ours))
        assertFalse(ShareIntents.acceptsStream(Uri.parse("content://$own/attachments/cookie.db"), ours))
        // The resolver drops a user id prefix before it looks the provider up.
        assertFalse(ShareIntents.acceptsStream(Uri.parse("content://0@$own/attachments/a.png"), ours))
        assertFalse(ShareIntents.acceptsStream(Uri.parse("content://10@$own/attachments/a.png"), ours))
        assertFalse(ShareIntents.acceptsStream(Uri.parse("content://${own.uppercase()}/attachments/a.png"), ours))
        assertFalse(ShareIntents.acceptsStream(Uri.parse("CONTENT://$own/attachments/a.png"), ours))
        // Not a provider at all: read with the app's own rights too.
        assertFalse(ShareIntents.acceptsStream(Uri.parse("file:///data/data/${app.packageName}/databases/a.db"), ours))
        assertFalse(ShareIntents.acceptsStream(Uri.fromFile(File("/sdcard/a.png")), ours))
        assertFalse(ShareIntents.acceptsStream(Uri.parse("android.resource://${app.packageName}/drawable/a"), ours))
        assertFalse(ShareIntents.acceptsStream(Uri.parse("content:///a.png"), ours))
        // An answer that cannot be had is a no.
        assertFalse(ShareIntents.acceptsStream(Uri.parse("content://$foreign/a.png")) { throw IllegalStateException() })
    }

    @Test fun ownProviderUriSharedToTheAppIsNotCopied() {
        val ours = readable(own, "attachments/private.png")
        val result = ShareIntents.read(app, send(ours))
        assertTrue(images(result).isEmpty())
        // The same image from another app's provider is taken: the filter is about whose provider it is.
        val theirs = readable(foreign)
        assertEquals(1, images(ShareIntents.read(app, send(theirs))).size)
    }

    @Test fun ownProviderUriInMultipleShareIsDroppedAndTheRestKept() {
        val ours = readable(own, "attachments/private.png")
        val theirs = readable(foreign)
        val intent = Intent(Intent.ACTION_SEND_MULTIPLE).setType("image/*")
            .putParcelableArrayListExtra(Intent.EXTRA_STREAM, arrayListOf(ours, Uri.parse("content://0@$own/x.png"), theirs))
        val copied = images(ShareIntents.read(app, intent))
        assertEquals(1, copied.size)
        assertArrayEquals(png, File(copied.single()).readBytes())
    }

    @Test fun textShareWithOwnUriKeepsTheText() {
        val ours = readable(own, "attachments/private.png")
        val result = ShareIntents.read(app, send(ours).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "hello"))
        assertEquals("hello", result?.get("text"))
        assertTrue(images(result).isEmpty())
    }

    @Test fun providersDeclaredByLibrariesCountAsOwn() {
        val pm = shadowOf(app.packageManager)
        pm.addProviderIfNotPresent(ComponentName(app.packageName, "dev.example.LibraryFileProvider")).apply {
            authority = "dev.example.library.files;dev.example.library.other"
        }
        assertTrue(ShareIntents.ownsAuthority(app, "dev.example.library.files"))
        assertTrue(ShareIntents.ownsAuthority(app, "DEV.example.library.other"))
        assertTrue(ShareIntents.ownsAuthority(app, "${app.packageName}.updates"))
        assertFalse(ShareIntents.ownsAuthority(app, foreign))
    }
}
