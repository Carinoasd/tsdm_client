package kzs.th000.tsdm_client

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import java.io.IOException

/** Only downloaded updates in the app's private cache can be handed to the system installer. */
class UpdateInstaller(private val context: Context) {
    class Failure(val code: String, override val message: String) : Exception(message)

    internal data class PackageIdentity(
        val packageName: String,
        val versionName: String?,
        val versionCode: Long,
        val signers: Set<String>,
    )

    fun updateDirectory(): File {
        try {
            val directory = File(context.cacheDir, "updates").canonicalFile
            if ((!directory.exists() && !directory.mkdirs()) || !directory.isDirectory) {
                throw Failure("update_directory_unavailable", "The update cache is unavailable.")
            }
            return directory
        } catch (_: IOException) {
            throw Failure("update_directory_unavailable", "The update cache is unavailable.")
        }
    }

    fun canInstallPackages(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
        context.packageManager.canRequestPackageInstalls()

    fun permissionIntent(): Intent = Intent(
        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
        Uri.parse("package:${context.packageName}"),
    )

    /** Parsing and certificate collection can read a large APK; call this on an IO dispatcher. */
    fun prepareInstall(path: String, version: String, versionCode: Long): Intent {
        val file = validateFile(updateDirectory(), path)
        val pm = context.packageManager
        @Suppress("DEPRECATION")
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        @Suppress("DEPRECATION")
        val archive = pm.getPackageArchiveInfo(file.path, flags)
            ?: throw Failure("invalid_update_apk", "The downloaded file is not a readable APK.")
        @Suppress("DEPRECATION")
        val installed = pm.getPackageInfo(context.packageName, flags)
        validateIdentity(identity(archive), identity(installed), version, versionCode)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.updates", file)
        return installerIntent(uri)
    }

    companion object {
        internal fun validateFile(directory: File, path: String): File {
            val file = try {
                File(path).canonicalFile
            } catch (_: IOException) {
                throw Failure("invalid_update_file", "The update file is unavailable.")
            }
            val root = directory.canonicalFile.path + File.separator
            if (!file.path.startsWith(root) || !file.isFile ||
                !file.name.endsWith(".apk", ignoreCase = true)
            ) {
                throw Failure("invalid_update_file", "The update file must be an APK in the private update cache.")
            }
            return file
        }

        @Suppress("DEPRECATION")
        internal fun identity(info: PackageInfo): PackageIdentity {
            // A conservative current-signer comparison also rejects debug/F-Droid builds signed with another key.
            // A future signing-key rotation needs an explicit compatibility policy; sharing any historical key
            // alone is not sufficient proof that one APK may update another.
            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.signingInfo?.let {
                    if (it.hasMultipleSigners()) it.apkContentsSigners
                    else it.signingCertificateHistory?.lastOrNull()?.let { signer -> arrayOf(signer) }
                }
            } else {
                info.signatures
            }
            return PackageIdentity(
                info.packageName,
                info.versionName,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong(),
                signatures?.map { it.toCharsString() }?.toSet() ?: emptySet(),
            )
        }

        internal fun validateIdentity(
            archive: PackageIdentity,
            installed: PackageIdentity,
            expectedVersion: String,
            expectedCode: Long,
        ) {
            if (archive.packageName != installed.packageName) {
                throw Failure("update_package_mismatch", "This APK belongs to a different application.")
            }
            if (archive.versionName != expectedVersion || archive.versionCode != expectedCode) {
                throw Failure("update_version_mismatch", "This APK does not match the selected release.")
            }
            if (archive.versionCode <= installed.versionCode) {
                throw Failure("update_not_newer", "This APK is not newer than the installed application.")
            }
            if (archive.signers.isEmpty() || installed.signers.isEmpty() || archive.signers != installed.signers) {
                throw Failure("update_signature_mismatch", "This APK is signed differently from the installed application.")
            }
        }

        internal fun installerIntent(uri: Uri): Intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = ClipData.newRawUri("Application update", uri)
        }
    }
}

/** A dedicated provider keeps all other cache files outside the shared directory. */
class UpdateFileProvider : FileProvider()
