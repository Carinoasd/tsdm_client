package kzs.th000.tsdm_client

import android.content.ContentValues
import android.os.Environment
import android.provider.MediaStore
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import org.junit.Assert.assertTrue
import java.io.File

/** Test-only public artifacts: shell cannot pull Android/data under scoped storage. */
object EmulatorEvidence {
    fun capture(device: UiDevice, name: String, hierarchy: Boolean = false) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val image = File(context.cacheDir, "emulator-evidence-$name.png")
        assertTrue(device.takeScreenshot(image))
        publish(image, "$name.png", "image/png")
        if (hierarchy) {
            val xml = File(context.cacheDir, "emulator-evidence-$name.xml")
            device.dumpWindowHierarchy(xml)
            publish(xml, "$name.xml", "application/xml")
        }
    }

    private fun publish(file: File, name: String, mime: String) {
        val resolver = InstrumentationRegistry.getInstrumentation().targetContext.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/tsdm-emulator-evidence")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = checkNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values))
        checkNotNull(resolver.openOutputStream(uri)).use { output -> file.inputStream().use { it.copyTo(output) } }
        resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
        check(file.delete())
    }
}
