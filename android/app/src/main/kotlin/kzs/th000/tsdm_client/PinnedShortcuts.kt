package kzs.th000.tsdm_client

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * "Add to home screen" of a forum or a thread: a shortcut the launcher pins, `forum-<fid>` or `thread-<tid>`, that
 * opens the way the launcher shortcuts of the app icon do. Its intent starts [ShortcutActivity] (not exported: the
 * launcher starts it on the app's behalf) with `tsdm://shortcut/<id>`, which hands it to [MainActivityImpl] with
 * [ShortcutKey]; [ShortcutsHandler] hands the id to Dart, which opens the page. The key never goes into the shortcut
 * (a launcher can read the intents of the shortcuts it pins): [ShortcutActivity] adds it each time.
 *
 * Asked by Dart on the shortcuts channel ([ShortcutsHandler.attach]): [IS_SUPPORTED], [REQUEST].
 *
 * Android 8 or later only. Before that ShortcutManagerCompat hands the shortcut to the launcher by a broadcast
 * (`INSTALL_SHORTCUT`), and the launcher starts its intent by itself, which may not start [ShortcutActivity]; nor can
 * a shortcut pinned that way be updated.
 *
 * [iconOf] gives the icon of a shortcut id (tests replace the app's drawables, which they do not have).
 */
class PinnedShortcuts(
    private val context: Context,
    private val iconOf: (String) -> IconCompat = { id -> IconCompat.createWithResource(context, iconResOf(id)) },
) {
    companion object {
        const val IS_SUPPORTED = "isPinShortcutSupported"
        const val REQUEST = "requestPinShortcut"

        /** The launcher was asked to pin the shortcut: it asks the user (or pins on its own). */
        const val REQUESTED = "requested"

        /** The shortcut was pinned already: its label is updated, nothing new is pinned. */
        const val UPDATED = "updated"

        /** The ids pinned: a forum or a thread, a positive id without a leading zero. */
        private val ID = Regex("(forum|thread)-[1-9][0-9]{0,9}")

        /** The longest label kept. Dart cuts them shorter already: this only bounds what is passed on. */
        private const val MAX_LABEL = 100

        /** Whether [id] is the id of a forum or a thread to pin. */
        fun isPinnableId(id: String?): Boolean = id != null && ID.matches(id)

        /** Whether the launcher pins shortcuts, on Android 8 or later ([sdk]: the system's, replaced in tests). */
        fun supported(context: Context, sdk: Int = Build.VERSION.SDK_INT): Boolean =
            sdk >= Build.VERSION_CODES.O && ShortcutManagerCompat.isRequestPinShortcutSupported(context)

        /** The intent of the shortcut [id]: [ShortcutActivity], without the key, with no flags beyond the system's. */
        fun intentOf(context: Context, id: String): Intent = Intent(Intent.ACTION_MAIN)
            .setClass(context, ShortcutActivity::class.java)
            .setData(Uri.parse("tsdm://shortcut/$id"))

        /** The two fixed icons: a forum and a thread; the launcher adds the app's own badge. */
        fun iconResOf(id: String): Int =
            if (id.startsWith("forum-")) R.drawable.ic_shortcut_forum else R.drawable.ic_shortcut_thread

        /** [this] cut to [max] UTF-16 units, never between the two of a surrogate pair. */
        private fun String.cut(max: Int): String {
            if (length <= max) return this
            val end = if (Character.isHighSurrogate(this[max - 1])) max - 1 else max
            return substring(0, end)
        }
    }

    /**
     * Answer a call of the shortcuts channel; false when it is none of [IS_SUPPORTED] and [REQUEST]. Arguments that are
     * not a map of strings pin nothing.
     */
    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            IS_SUPPORTED -> result.success(supported(context))
            REQUEST -> {
                val arguments = call.arguments as? Map<*, *>
                result.success(
                    request(
                        arguments?.get("id") as? String,
                        arguments?.get("shortLabel") as? String,
                        arguments?.get("longLabel") as? String,
                    ),
                )
            }
            else -> return false
        }
        return true
    }

    /**
     * Ask the launcher to pin the forum or thread [id], labelled [shortLabel] (under the icon) and [longLabel] (where
     * there is room). One pinned already is updated first and asked for again: the launcher that has it answers at once
     * without asking the user, one that does not (the default launcher changed since) asks.
     *
     * Returns [REQUESTED] or [UPDATED], null when nothing was asked: not a forum or thread id, no label, a launcher that
     * does not pin, the system refusing (the app not in front).
     */
    fun request(id: String?, shortLabel: String?, longLabel: String?): String? {
        if (id == null || !isPinnableId(id) || !supported(context)) return null
        val short = shortLabel?.trim()?.cut(MAX_LABEL)
        if (short.isNullOrEmpty()) return null
        val long = longLabel?.trim()?.cut(MAX_LABEL)?.takeIf { it.isNotEmpty() } ?: short
        return try {
            val info = ShortcutInfoCompat.Builder(context, id)
                .setShortLabel(short)
                .setLongLabel(long)
                .setIcon(iconOf(id))
                .setIntent(intentOf(context, id))
                .build()
            val pinned = ShortcutManagerCompat.getShortcuts(context, ShortcutManagerCompat.FLAG_MATCH_PINNED)
                .any { it.id == id }
            if (pinned) ShortcutManagerCompat.updateShortcuts(context, listOf(info))
            when {
                !ShortcutManagerCompat.requestPinShortcut(context, info, null) -> null
                pinned -> UPDATED
                else -> REQUESTED
            }
        } catch (_: Exception) {
            null
        }
    }
}
