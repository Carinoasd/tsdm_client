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

    /**
     * Enable the alias of [name] and disable the others. Returns false when [name] is not an icon of the app.
     *
     * The forums and threads pinned to the home screen belong to the alias enabled when they were pinned, and the
     * launcher removes them with it: [moveShortcuts] ties them to the new alias in between, when both are enabled
     * ([PinnedShortcuts.moveTo]). The launcher hears of the aliases switched later (the system sends the change of
     * components enabled without killing the app about a second after), and of the shortcuts updated at once. Nothing
     * is done when the aliases are as wanted already (each start of the app applies the icon it shows).
     */
    fun apply(
        context: Context,
        name: String,
        moveShortcuts: (ComponentName) -> Unit = { PinnedShortcuts.moveTo(context, it) },
    ): Boolean {
        val chosen = aliases[name] ?: return false
        val manager = context.packageManager
        if (aliases.values.all { isEnabled(context, manager, it) == (it == chosen) }) return true
        // The new entry first: the launcher never sees an app without any entry.
        setEnabled(context, manager, chosen, true)
        moveShortcuts(ComponentName(context, "kzs.th000.tsdm_client.$chosen"))
        for (alias in aliases.values) {
            if (alias != chosen) setEnabled(context, manager, alias, false)
        }
        return true
    }

    /** Whether [alias] is enabled: the manifest default (the default alias only) when nothing was set. */
    private fun isEnabled(context: Context, manager: PackageManager, alias: String): Boolean =
        when (manager.getComponentEnabledSetting(ComponentName(context, "kzs.th000.tsdm_client.$alias"))) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED -> false
            else -> alias == aliases.values.first()
        }

    private fun setEnabled(context: Context, manager: PackageManager, alias: String, enabled: Boolean) {
        if (isEnabled(context, manager, alias) == enabled) return
        val wanted = if (enabled) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } else {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        }
        manager.setComponentEnabledSetting(
            ComponentName(context, "kzs.th000.tsdm_client.$alias"),
            wanted,
            PackageManager.DONT_KILL_APP,
        )
    }
}
