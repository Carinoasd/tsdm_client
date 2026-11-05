package kzs.th000.tsdm_client

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The channel Dart tells the home screen widget's state over (`lib/features/home_widget`).
 *
 * One method, [UPDATE], with the whole state: `uid` (null when no account is in use), `notice`, `personalMessage`
 * and `checkedInDay` (the ISO date of today's check-in, null when none). A null count keeps the one stored while the
 * account is the same: the app has not counted yet in this run (just started), the background service may have; for
 * another account it is [HomeWidgetState.UNKNOWN_COUNT], a dash, until counted. The
 * day is stored as Dart tells it, never taken from the clock here: told at 23:59:59 and stored after midnight it would
 * be the wrong day. The state is stored ([HomeWidgetStore]) and every placed widget is drawn again.
 */
class HomeWidgetChannel {
    companion object {
        const val CHANNEL = "kzs.th000.tsdm_client/homeWidget"
        const val UPDATE = "update"
    }

    private var channel: MethodChannel? = null

    fun attach(messenger: BinaryMessenger, context: Context) {
        val appContext = context.applicationContext
        channel = MethodChannel(messenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                if (call.method != UPDATE) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val uid = (call.argument<Any>("uid") as? Number)?.toInt()?.takeIf { id -> id > 0 }
                val checkedInDay = (call.argument<Any>("checkedInDay") as? String)?.takeIf { day -> day.isNotEmpty() }
                val current = HomeWidgetStore.read(appContext)
                val kept = when {
                    uid == null -> HomeWidgetState.EMPTY
                    uid == current.uid -> current
                    else -> current.copy(notice = HomeWidgetState.UNKNOWN_COUNT, personalMessage = HomeWidgetState.UNKNOWN_COUNT)
                }
                val notice = (call.argument<Any>("notice") as? Number)?.toInt() ?: kept.notice
                val personalMessage = (call.argument<Any>("personalMessage") as? Number)?.toInt() ?: kept.personalMessage
                HomeWidgetStore.write(
                    appContext,
                    HomeWidgetState(
                        uid = uid,
                        notice = notice.coerceAtLeast(HomeWidgetState.UNKNOWN_COUNT),
                        personalMessage = personalMessage.coerceAtLeast(HomeWidgetState.UNKNOWN_COUNT),
                        checkedInDay = if (uid != null) checkedInDay else null,
                    ),
                )
                HomeWidgetProvider.refresh(appContext)
                result.success(true)
            }
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }
}
