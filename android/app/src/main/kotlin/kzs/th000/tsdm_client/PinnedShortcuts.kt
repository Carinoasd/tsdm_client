package kzs.th000.tsdm_client

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.net.Uri
import android.os.Build
import android.util.Log
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
 * A pinned shortcut belongs to an activity of the launcher's: the main activity enabled when it was pinned, the alias
 * of the app icon then shown. Switching the app icon disables that alias, and the launcher removes the items of a
 * component disabled: [AppIconSwitcher] moves the shortcuts to the new alias first ([moveTo]).
 *
 * [iconOf] gives the icon of a shortcut id (tests replace the app's drawables, which they do not have). [pinnedIds],
 * [update] and [askToPin] are the system's: the ids pinned on any launcher, the update of a shortcut, and the request to
 * the default launcher.
 */
class PinnedShortcuts(
    private val context: Context,
    private val iconOf: (String) -> IconCompat = { id -> IconCompat.createWithResource(context, iconResOf(id)) },
    private val pinnedIds: () -> Set<String> = {
        ShortcutManagerCompat.getShortcuts(context, ShortcutManagerCompat.FLAG_MATCH_PINNED).map { it.id }.toSet()
    },
    private val update: (ShortcutInfoCompat) -> Boolean = { ShortcutManagerCompat.updateShortcuts(context, listOf(it)) },
    private val askToPin: (ShortcutInfoCompat) -> Boolean = { ShortcutManagerCompat.requestPinShortcut(context, it, null) },
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

        private const val TAG = "PINNED_SHORTCUTS"

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

        /**
         * Tie the forums and threads pinned to [activity], the alias of the app icon about to be shown, which must be
         * enabled already (the system takes a main activity only), while the alias they belong to is still enabled.
         * The launcher rebuilds its item of an updated shortcut from the shortcut's activity, so the items moved are
         * not the disabled component's any more when the old alias goes. The shortcuts of `shortcuts.xml` are not the
         * app's to update; the system publishes them again for the alias enabled.
         *
         * Returns how many moved. Never throws: the icon switches all the same. A failure is logged: the launcher then
         * removes the shortcuts with the old alias.
         */
        fun moveTo(context: Context, activity: ComponentName, sdk: Int = Build.VERSION.SDK_INT): Int {
            if (sdk < Build.VERSION_CODES.O) return 0
            return try {
                val manager = context.getSystemService(ShortcutManager::class.java) ?: return 0
                // An update with the activity alone: the label, the icon and the intent are kept.
                val moved = manager.pinnedShortcuts
                    .filter { isPinnableId(it.id) && it.activity != activity }
                    .map { ShortcutInfo.Builder(context, it.id).setActivity(activity).build() }
                when {
                    moved.isEmpty() -> 0
                    manager.updateShortcuts(moved) -> moved.size
                    else -> {
                        Log.w(TAG, "pinned shortcuts not moved to $activity: update refused")
                        0
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "pinned shortcuts not moved to $activity", e)
                0
            }
        }

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
     * there is room). One pinned already is only updated (labels and icon): the system hands a request to the launcher
     * even for a shortcut it has, and Pixel Launcher then asks the user again and adds a second icon. One removed from
     * the home screen is no longer pinned (the system drops a shortcut no launcher pins) and is asked for again.
     *
     * "Pinned" is the system's answer to the app: pinned on any launcher of the user, the default one or another still
     * installed that pinned it before (the app is not told which). On a default launcher changed since, the shortcut is
     * then updated where it is, and the new launcher is not asked.
     *
     * Returns [REQUESTED] or [UPDATED], null when nothing was asked or updated: not a forum or thread id, no label, a
     * launcher that does not pin, the system refusing (the app not in front, too many updates).
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
            when {
                id in pinnedIds() -> if (update(info)) UPDATED else null
                askToPin(info) -> REQUESTED
                else -> null
            }
        } catch (_: Exception) {
            null
        }
    }
}
