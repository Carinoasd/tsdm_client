package kzs.th000.tsdm_client

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager

/**
 * The app icon the user picked: each icon is the launcher entry of an `activity-alias` of [MainActivityImpl] (see the
 * manifest), and exactly one of them is enabled.
 */
object AppIconSwitcher {
    /** Icon name sent by Dart, to the alias class that shows it. The first is the one enabled at install. */
    private val aliases = linkedMapOf(
        "default" to "MainActivity",
        "dark" to "IconDark",
        "mono" to "IconMono",
        "pink" to "IconPink",
    )

    /** Enable the alias of [name] and disable the others. Returns false when [name] is not an icon of the app. */
    fun apply(context: Context, name: String): Boolean {
        val chosen = aliases[name] ?: return false
        val manager = context.packageManager
        // The new entry first: the launcher never sees an app without any entry.
        setEnabled(context, manager, chosen, true)
        for (alias in aliases.values) {
            if (alias != chosen) setEnabled(context, manager, alias, false)
        }
        return true
    }

    private fun setEnabled(context: Context, manager: PackageManager, alias: String, enabled: Boolean) {
        val component = ComponentName(context, "kzs.th000.tsdm_client.$alias")
        val wanted = if (enabled) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } else {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        }
        // The manifest default (enabled for the default alias only) counts as the state when nothing was set.
        val current = manager.getComponentEnabledSetting(component)
        val isEnabled = when (current) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED -> false
            else -> alias == aliases.values.first()
        }
        if (isEnabled == enabled) return
        manager.setComponentEnabledSetting(component, wanted, PackageManager.DONT_KILL_APP)
    }
}
