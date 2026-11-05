package kzs.th000.tsdm_client

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews

/**
 * The home screen widget (`res/xml/home_widget_info.xml`, layout `res/layout/home_widget.xml`): the unread notice
 * and personal message counts of the account in use and whether it checked in today.
 *
 * It draws what [HomeWidgetStore] holds; the app writes there through [HomeWidgetChannel] and the background message
 * service through [HomeWidgetSyncListener], both calling [refresh]. Taps start [MainActivity] with the shortcut URIs
 * of `res/xml/shortcuts.xml`, so [ShortcutsHandler] and Dart treat them like the launcher shortcuts: the check-in
 * cell checks in while not checked in yet, the rest of the widget (and the cell once checked in) opens the notices.
 */
class HomeWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        val views = build(context, HomeWidgetStore.read(context))
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    companion object {
        const val SHORTCUT_CHECKIN = "tsdm://shortcut/checkin"
        const val SHORTCUT_NOTICE = "tsdm://shortcut/notice"

        private const val REQUEST_NOTICE = 0
        private const val REQUEST_CHECKIN = 1

        /** The most a count shows; the exact number is in the app. */
        private const val COUNT_CAP = 99

        /** Draw every placed widget again from the stored state. Nothing happens when none is placed. */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context) ?: return
            val ids = manager.getAppWidgetIds(ComponentName(context, HomeWidgetProvider::class.java))
            if (ids.isEmpty()) return
            val views = build(context, HomeWidgetStore.read(context))
            for (id in ids) {
                manager.updateAppWidget(id, views)
            }
        }

        fun build(context: Context, state: HomeWidgetState): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.home_widget)
            views.setTextViewText(R.id.home_widget_notice_count, count(state, state.notice))
            views.setTextViewText(R.id.home_widget_pm_count, count(state, state.personalMessage))

            val checked = state.loggedIn && state.checkedInToday()
            views.setImageViewResource(
                R.id.home_widget_checkin_icon,
                if (checked) R.drawable.ic_home_widget_checked else R.drawable.ic_home_widget_unchecked,
            )
            views.setTextViewText(
                R.id.home_widget_checkin_label,
                context.getString(if (checked) R.string.home_widget_checked_in else R.string.home_widget_not_checked_in),
            )
            // A pill behind the cell while it is a button; flat once checked in.
            views.setInt(R.id.home_widget_checkin, "setBackgroundResource", if (checked) 0 else R.drawable.home_widget_button)

            val notice = open(context, SHORTCUT_NOTICE, REQUEST_NOTICE)
            views.setOnClickPendingIntent(R.id.home_widget_root, notice)
            views.setOnClickPendingIntent(
                R.id.home_widget_checkin,
                if (checked) notice else open(context, SHORTCUT_CHECKIN, REQUEST_CHECKIN),
            )
            return views
        }

        private fun count(state: HomeWidgetState, value: Int): String = when {
            !state.loggedIn -> "–"
            value > COUNT_CAP -> "$COUNT_CAP+"
            else -> value.toString()
        }

        /**
         * Start [MainActivity] with [data], the way a launcher shortcut does (`ACTION_MAIN` with the `tsdm://shortcut`
         * URI, see [ShortcutsHandler.shortcutIdOf]). `CLEAR_TOP` hands the intent to the activity already running
         * (`singleTop`) instead of stacking another one above whatever it opened; an activity above it (a file picker,
         * the share sheet, [InteractiveHtmlActivity]) is closed, as a tap meaning "go to the notices" should.
         */
        private fun open(context: Context, data: String, requestCode: Int): PendingIntent {
            val intent = Intent(Intent.ACTION_MAIN)
                .setClass(context, MainActivity::class.java)
                .setData(Uri.parse(data))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            return PendingIntent.getActivity(
                context,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
    }
}
