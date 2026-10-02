package kzs.th000.tsdm_client

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.Signature
import android.content.pm.SigningInfo
import android.net.Uri
import android.provider.Settings
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadow.api.Shadow
import org.w3c.dom.Element

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 28, 35], manifest = Config.NONE)
class UpdateInstallerTest {
    @get:Rule val temporary = TemporaryFolder()

    private val installed = UpdateInstaller.PackageIdentity("com.tsdm.tsdm_client", "1.24.0", 749, setOf("release-key"))
    private val next = installed.copy(versionName = "1.25.0", versionCode = 759)
    private val context: android.app.Application get() = RuntimeEnvironment.getApplication()

    private fun fails(code: String, action: () -> Unit) {
        val failure = assertThrows(UpdateInstaller.Failure::class.java) { action() }
        assertEquals(code, failure.code)
    }

    @Test fun onlyACompleteApkInsideUpdateCacheIsEligible() {
        val updates = temporary.newFolder("updates")
        val apk = File(updates, "release.apk").apply { writeText("fixture") }
        assertEquals(apk.canonicalFile, UpdateInstaller.validateFile(updates, apk.path))
        val partial = File(updates, "release.apk.part").apply { writeText("incomplete") }
        val fakeDirectory = File(updates, "directory.apk").apply { mkdir() }
        for (file in listOf(partial, fakeDirectory, File(updates, "missing.apk"), updates)) {
            fails("invalid_update_file") { UpdateInstaller.validateFile(updates, file.path) }
        }
    }

    @Test fun canonicalTraversalAndSiblingPrefixCannotEscapeCache() {
        val updates = temporary.newFolder("updates")
        val outside = temporary.newFile("outside.apk")
        val sibling = File(temporary.newFolder("updates-other"), "other.apk").apply { writeText("fixture") }
        val child = File(updates, "nested").apply { mkdir() }
        for (path in listOf(outside.path, sibling.path, File(child, "../../outside.apk").path)) {
            fails("invalid_update_file") { UpdateInstaller.validateFile(updates, path) }
        }
    }

    @Test fun updateDirectoryIsPrivateCanonicalCacheSubdirectory() {
        val directory = UpdateInstaller(context).updateDirectory()
        assertEquals(File(context.cacheDir, "updates").canonicalFile, directory)
        assertTrue(directory.isDirectory)
    }

    @Test
    @Suppress("DEPRECATION")
    fun everyInstallRequestReadsTheArchiveAgainBeforeGrantingAccess() {
        val installer = UpdateInstaller(context)
        val apk = File(installer.updateDirectory(), "candidate.apk").apply { writeText("fixture") }
        val archive = PackageInfo().apply {
            packageName = "unrelated.app"
            versionName = "1.25.0"
            versionCode = 759
        }
        shadowOf(context.packageManager).setPackageArchiveInfo(apk.path, archive)
        fails("update_package_mismatch") { installer.prepareInstall(apk.path, "1.25.0", 759) }
        archive.packageName = context.packageName
        archive.versionName = "1.26.0"
        fails("update_version_mismatch") { installer.prepareInstall(apk.path, "1.25.0", 759) }
    }

    @Test fun newerSameSignedReleaseIsAcceptedAcrossApkVariants() {
        // Previous universal 749 -> next universal 759, and previous ARM64 743 -> next universal 759.
        for (code in listOf(743L, 749L)) {
            UpdateInstaller.validateIdentity(next, installed.copy(versionCode = code), "1.25.0", 759)
        }
    }

    @Test fun wrongPackageAndWrongSelectedReleaseAreRejected() {
        fails("update_package_mismatch") {
            UpdateInstaller.validateIdentity(next.copy(packageName = "unrelated.app"), installed, "1.25.0", 759)
        }
        for (candidate in listOf(next.copy(versionName = "1.26.0"), next.copy(versionCode = 753))) {
            fails("update_version_mismatch") { UpdateInstaller.validateIdentity(candidate, installed, "1.25.0", 759) }
        }
    }

    @Test fun equalAndOlderVersionCodesAreRejected() {
        for (code in listOf(749L, 739L)) {
            fails("update_not_newer") {
                UpdateInstaller.validateIdentity(next.copy(versionCode = code), installed, "1.25.0", code)
            }
        }
    }

    @Test fun differentMissingAndPartialSignerSetsAreRejected() {
        for (signers in listOf(setOf("debug-key"), setOf("fdroid-key"), emptySet())) {
            fails("update_signature_mismatch") {
                UpdateInstaller.validateIdentity(next.copy(signers = signers), installed, "1.25.0", 759)
            }
        }
        fails("update_signature_mismatch") {
            UpdateInstaller.validateIdentity(next, installed.copy(signers = setOf("release-key", "second-key")), "1.25.0", 759)
        }
        fails("update_signature_mismatch") {
            UpdateInstaller.validateIdentity(next, installed.copy(signers = emptySet()), "1.25.0", 759)
        }
    }

    @Test
    @Config(sdk = [28, 35])
    fun signingIdentityUsesCurrentSignerAndAllMultipleSigners() {
        val original = Signature("01")
        val current = Signature("02")
        val signingInfo = Shadow.newInstanceOf(SigningInfo::class.java)
        shadowOf(signingInfo).setSignatures(arrayOf(current))
        shadowOf(signingInfo).setPastSigningCertificates(arrayOf(original, current))
        val info = PackageInfo().apply {
            packageName = installed.packageName
            versionName = "1.25.0"
            setLongVersionCode(759)
            this.signingInfo = signingInfo
        }
        assertEquals(setOf(current.toCharsString()), UpdateInstaller.identity(info).signers)
        shadowOf(signingInfo).setSignatures(arrayOf(original, current))
        assertEquals(setOf(original.toCharsString(), current.toCharsString()), UpdateInstaller.identity(info).signers)
    }

    @Test
    @Config(sdk = [24, 27])
    @Suppress("DEPRECATION")
    fun legacyAndroidChecksLegacySignatures() {
        val info = PackageInfo().apply {
            packageName = installed.packageName
            versionName = "1.25.0"
            versionCode = 759
            signatures = arrayOf(Signature("01"))
        }
        assertEquals(setOf("01"), UpdateInstaller.identity(info).signers)
        assertEquals(759L, UpdateInstaller.identity(info).versionCode)
    }

    @Test
    @Config(sdk = [26, 28, 35])
    fun permissionStateIsReadAgainAfterReturningFromSettings() {
        val installer = UpdateInstaller(context)
        shadowOf(context.packageManager).setCanRequestPackageInstalls(false)
        assertFalse(installer.canInstallPackages())
        shadowOf(context.packageManager).setCanRequestPackageInstalls(true)
        assertTrue(installer.canInstallPackages())
        shadowOf(context.packageManager).setCanRequestPackageInstalls(false)
        assertFalse(installer.canInstallPackages())
        val intent = installer.permissionIntent()
        assertEquals(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, intent.action)
        assertEquals("package:${context.packageName}", intent.dataString)
    }

    @Test
    @Config(sdk = [24])
    fun preOreoDoesNotCallUnavailablePerAppPermissionApi() {
        assertTrue(UpdateInstaller(context).canInstallPackages())
    }

    @Test fun installerGetsOnlyTemporaryReadAccessToContentUri() {
        val uri = Uri.parse("content://com.tsdm.tsdm_client.updates/updates/release.apk")
        val intent = UpdateInstaller.installerIntent(uri)
        assertEquals(Intent.ACTION_VIEW, intent.action)
        assertEquals("application/vnd.android.package-archive", intent.type)
        assertEquals(uri, intent.data)
        assertEquals(uri, intent.clipData!!.getItemAt(0).uri)
        assertEquals(Intent.FLAG_GRANT_READ_URI_PERMISSION, intent.flags)
        assertNull(intent.selector)
        assertNull(intent.component)
    }

    @Test fun manifestProviderExposesOnlyThePrivateUpdatesDirectory() {
        val manifest = File(requireNotNull(System.getProperty("appManifest")))
        val builder = DocumentBuilderFactory.newInstance().newDocumentBuilder()
        val root = builder.parse(manifest).documentElement
        val providers = root.getElementsByTagName("provider")
        val provider = (0 until providers.length).map { providers.item(it) as Element }
            .single { it.getAttribute("android:name") == "kzs.th000.tsdm_client.UpdateFileProvider" }
        assertEquals("\${applicationId}.updates", provider.getAttribute("android:authorities"))
        assertEquals("false", provider.getAttribute("android:exported"))
        assertEquals("true", provider.getAttribute("android:grantUriPermissions"))
        val metadata = provider.getElementsByTagName("meta-data").item(0) as Element
        assertEquals("android.support.FILE_PROVIDER_PATHS", metadata.getAttribute("android:name"))
        assertEquals("@xml/update_file_paths", metadata.getAttribute("android:resource"))
        val paths = builder.parse(File(manifest.parentFile, "res/xml/update_file_paths.xml")).documentElement
        val children = (0 until paths.childNodes.length).map { paths.childNodes.item(it) }.filterIsInstance<Element>()
        assertEquals(1, children.size)
        assertEquals("cache-path", children.single().tagName)
        assertEquals("updates/", children.single().getAttribute("path"))
        val permissions = root.getElementsByTagName("uses-permission")
        assertTrue((0 until permissions.length).any {
            (permissions.item(it) as Element).getAttribute("android:name") == "android.permission.REQUEST_INSTALL_PACKAGES"
        })
    }
}
