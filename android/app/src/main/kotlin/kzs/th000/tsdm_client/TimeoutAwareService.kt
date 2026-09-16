package kzs.th000.tsdm_client

import android.content.Intent
import android.util.Log
import id.flutter.flutter_background_service.BackgroundService

class TimeoutAwareService : BackgroundService() {
    companion object {
        const val TAG = "TimeoutAwareService"
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "Foreground service timeout: startId=$startId fgsType=$fgsType")
        stopSelf()
    }
}
