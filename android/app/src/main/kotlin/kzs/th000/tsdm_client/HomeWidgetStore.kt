package kzs.th000.tsdm_client

import android.content.Context
import java.time.LocalDate

/**
 * What the home screen widget shows: the account in use and its unread counts, and the day it checked in.
 *
 * [checkedInDay] is the device-local day (ISO date, `yyyy-MM-dd` like [LocalDate.toString]) of the check-in the app
 * last told, null when it told "not checked in": the widget compares it with today when it draws, so yesterday's
 * check-in is over at midnight without the app saying anything.
 */
data class HomeWidgetState(
    val uid: Int?,
    val notice: Int,
    val personalMessage: Int,
    val checkedInDay: String?,
) {
    val loggedIn: Boolean get() = uid != null

    fun checkedInToday(today: LocalDate = LocalDate.now()): Boolean = checkedInDay == today.toString()

    companion object {
        val EMPTY = HomeWidgetState(uid = null, notice = 0, personalMessage = 0, checkedInDay = null)
    }
}

/** Where the widget state is kept: SharedPreferences, so the widget draws without any Flutter engine running. */
object HomeWidgetStore {
    private const val PREFS = "home_widget"
    private const val KEY_UID = "uid"
    private const val KEY_NOTICE = "notice"
    private const val KEY_PERSONAL_MESSAGE = "personalMessage"
    private const val KEY_CHECKED_IN_DAY = "checkedInDay"

    fun read(context: Context): HomeWidgetState {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val uid = prefs.getInt(KEY_UID, 0)
        return HomeWidgetState(
            uid = if (uid > 0) uid else null,
            notice = prefs.getInt(KEY_NOTICE, 0),
            personalMessage = prefs.getInt(KEY_PERSONAL_MESSAGE, 0),
            checkedInDay = prefs.getString(KEY_CHECKED_IN_DAY, null),
        )
    }

    fun write(context: Context, state: HomeWidgetState) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putInt(KEY_UID, state.uid ?: 0)
            .putInt(KEY_NOTICE, state.notice)
            .putInt(KEY_PERSONAL_MESSAGE, state.personalMessage)
            .putString(KEY_CHECKED_IN_DAY, state.checkedInDay)
            .apply()
    }

    /**
     * The unread counts a background sync brought for account [uid]: stored when that is the account the widget
     * shows, so another account's sync (every account is synced when the setting is on) never shows up. Returns
     * whether anything changed.
     */
    fun writeCounts(context: Context, uid: Int, notice: Int, personalMessage: Int): Boolean {
        val current = read(context)
        if (current.uid != uid) return false
        val next = current.copy(notice = notice, personalMessage = personalMessage)
        if (next == current) return false
        write(context, next)
        return true
    }
}
