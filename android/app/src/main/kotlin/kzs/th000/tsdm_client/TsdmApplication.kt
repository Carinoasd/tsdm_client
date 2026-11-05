package kzs.th000.tsdm_client

import android.app.Application

/** The app's process: installs what has to listen for as long as the process lives, activity or not. */
class TsdmApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        HomeWidgetSyncListener.install(this)
    }
}
