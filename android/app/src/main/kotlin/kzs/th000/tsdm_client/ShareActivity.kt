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
 *
 * `CLEAR_TOP` also finishes whatever is stacked over [MainActivity] in the app's task (an [InteractiveHtmlActivity]
 * showing interactive content): a share is handled on the app's own pages, so the app comes back to them.
 */
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val received = intent
        // Only a share the sheet just sent: not one replayed from the recents or after the process was recreated.
        val replayed = savedInstanceState != null ||
            (received.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        if (!replayed && ShareIntents.isShare(received)) {
            // The copy keeps action, type, extras and clip data (the uri grants travel with the clip data and the
            // grant flag). The sender's flags are replaced, not added to: NEW_DOCUMENT or MULTIPLE_TASK from a sender
            // would open another task, the very thing this activity is for.
            val forward = Intent(received).apply {
                setClass(this@ShareActivity, MainActivity::class.java)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
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
