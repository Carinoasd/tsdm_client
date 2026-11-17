package kzs.th000.tsdm_client

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import java.security.SecureRandom

/**
 * The secret the app's own shortcuts carry to [MainActivityImpl] ([EXTRA]), so [ShortcutsHandler] tells them from the
 * same `tsdm://shortcut/<id>` intent sent by another app: [MainActivityImpl] and its launcher aliases are exported,
 * and any app may start them with `ACTION_MAIN` and that data.
 *
 * Made once, kept in the app's private preferences (left out of the system backups). Only the app reads it: the
 * launcher shortcuts get it through [ShortcutActivity], the widget puts it into its own pending intents.
 */
object ShortcutKey {
    const val EXTRA = "kzs.th000.tsdm_client.SHORTCUT_KEY"

    private const val PREFS = "tsdm_shortcuts"
    private const val KEY = "key"

    fun of(context: Context): String {
        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(KEY, null)?.takeIf { it.isNotEmpty() }?.let { return it }
        val bytes = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val key = bytes.joinToString("") { "%02x".format(it) }
        prefs.edit().putString(KEY, key).commit()
        return key
    }
}

/**
 * The target of the launcher shortcuts (`res/xml/shortcuts.xml`) and of the forums and threads pinned to the home
 * screen ([PinnedShortcuts]), not exported: only the launcher starts it, on the app's behalf. It shows nothing, hands
 * the shortcut to [MainActivityImpl] with [ShortcutKey] (`NEW_TASK`, `CLEAR_TOP`, `SINGLE_TOP`, as the widget's taps
 * go) and finishes at once.
 *
 * A launcher shortcut starts it as the root of the app's task (`NEW_TASK | CLEAR_TASK`, as it started
 * [MainActivityImpl] before), so the task keeps its intent: started again from the recent apps (the task emptied), it
 * opens the app without running the shortcut a second time. A pinned one starts it with `NEW_TASK` alone: on top of
 * the app's task when there is one, whose [MainActivityImpl] gets the shortcut as a new intent, else as the root of a
 * new one, as above.
 */
class ShortcutActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val received = intent
        val replayed = savedInstanceState != null ||
            (received.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        val target = when {
            // The recent apps start the root of an emptied task again: the app opens, the shortcut is not run twice.
            replayed -> open(this)
            ShortcutsHandler.idOfData(received) != null -> forward(this, received)
            else -> null
        }
        if (target != null) {
            try {
                startActivity(target)
            } catch (_: Exception) {
                // Nothing to show: the shortcut is dropped.
            }
        }
        finish()
    }

    companion object {
        /** The intent opening [MainActivityImpl] without a shortcut. */
        fun open(context: Context): Intent = Intent(Intent.ACTION_MAIN)
            .setClass(context, MainActivityImpl::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)

        /** The intent handing the shortcut of [received] to [MainActivityImpl], signed with [ShortcutKey]. */
        fun forward(context: Context, received: Intent): Intent = Intent(Intent.ACTION_MAIN)
            .setClass(context, MainActivityImpl::class.java)
            .setData(received.data)
            .putExtra(ShortcutKey.EXTRA, ShortcutKey.of(context))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }
}
