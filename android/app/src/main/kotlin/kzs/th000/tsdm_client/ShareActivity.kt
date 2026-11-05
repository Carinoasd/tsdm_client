package kzs.th000.tsdm_client

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * The target of the system share sheet (`ACTION_SEND`, `ACTION_SEND_MULTIPLE`), handing the share to [MainActivity] in
 * this app's own task.
 *
 * Another app's share sheet starts its target inside the sender's task: a `singleTop` [MainActivity] running in its
 * own task would not be reused, and a second instance of the whole app (a second Flutter engine) would start in the
 * sender's task. This activity shows nothing, forwards the intent to the app's task (`NEW_TASK`, `CLEAR_TOP`,
 * `SINGLE_TOP`: the running [MainActivity] gets it in `onNewIntent`, else one starts with it) and finishes at once.
 * The uri grants of the shared images travel with the clip data and the grant flag.
 */
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val received = intent
        // Only a share the sheet just sent: not one replayed from the recents or after the process was recreated.
        val replayed = savedInstanceState != null ||
            (received.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        if (!replayed && ShareIntents.isShare(received)) {
            val forward = Intent(received).apply {
                setClass(this@ShareActivity, MainActivity::class.java)
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
                // The system keeps the grant of a forwarded uri only when it is in the clip data.
                if (clipData == null && received.clipData != null) clipData = received.clipData
            }
            try {
                startActivity(forward)
            } catch (_: Exception) {
                // Nothing to show: the share is dropped.
            }
        }
        finish()
    }
}
