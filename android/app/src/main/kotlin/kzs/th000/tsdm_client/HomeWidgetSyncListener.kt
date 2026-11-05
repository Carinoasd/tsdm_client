package kzs.th000.tsdm_client

import android.content.Context
import id.flutter.flutter_background_service.FlutterBackgroundServicePlugin
import id.flutter.flutter_background_service.Pipe
import org.json.JSONObject

/**
 * Keeps the home screen widget's counts current while only the background message service runs (#80).
 *
 * The service's isolate announces each sync with `service.invoke('synced', {uid, notice, personalMessage, ...})`
 * (`lib/features/background_sync/background_sync_entry.dart`). The plugin carries that to the app's engine over its
 * process-wide [Pipe] (`FlutterBackgroundServicePlugin.mainPipe`); with the app's activity gone (swiped away, the
 * service kept the process) nothing listens there and the widget would keep the counts of the last time the app was
 * open. This listener is added to the same pipe by [TsdmApplication], so it hears every announcement for as long as
 * the process lives, and stores the counts when they are the widget's account's ([HomeWidgetStore.writeCounts]).
 *
 * The pipe is the plugin's public static bus between its two engines; a plugin update that changes it fails this
 * file's compilation, not the widget at runtime.
 */
object HomeWidgetSyncListener : Pipe.PipeListener {
    private const val METHOD_SYNCED = "synced"

    private var appContext: Context? = null

    fun install(context: Context) {
        if (appContext != null) return
        appContext = context.applicationContext
        FlutterBackgroundServicePlugin.mainPipe.addListener(this)
    }

    override fun onReceived(data: JSONObject) {
        val context = appContext ?: return
        if (data.optString("method") != METHOD_SYNCED) return
        val args = data.optJSONObject("args") ?: return
        val uid = args.optInt("uid", 0)
        val notice = args.optInt("notice", -1)
        val personalMessage = args.optInt("personalMessage", -1)
        if (uid <= 0 || notice < 0 || personalMessage < 0) return
        if (HomeWidgetStore.writeCounts(context, uid, notice, personalMessage)) {
            HomeWidgetProvider.refresh(context)
        }
    }
}
