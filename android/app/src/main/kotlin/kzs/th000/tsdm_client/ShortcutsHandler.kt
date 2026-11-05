package kzs.th000.tsdm_client

import android.content.Intent
import android.os.Bundle
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The launcher shortcuts of the app icon (`res/xml/shortcuts.xml`): each starts [MainActivity] with
 * `tsdm://shortcut/<id>` as data, and the id is handed to Dart, which navigates.
 *
 * A cold start keeps the id until Dart asks for it ([GET_INITIAL_SHORTCUT]); an activity already running gets the
 * intent through `onNewIntent` and the id is pushed to Dart ([ON_SHORTCUT]), once Dart has asked for the initial one
 * (before that Dart is not listening yet and the id is kept for its question instead). An activity recreated by the
 * system (restored state, brought back from the recent apps) ignores the shortcut it was started with, so the
 * shortcut runs once.
 */
class ShortcutsHandler {
    companion object {
        const val CHANNEL = "kzs.th000.tsdm_client/shortcuts"
        const val GET_INITIAL_SHORTCUT = "getInitialShortcut"
        const val ON_SHORTCUT = "onShortcut"

        private const val SCHEME = "tsdm"
        private const val HOST = "shortcut"

        /** The shortcut id of [intent], null when it is not a shortcut intent or a relaunch from the recent apps. */
        fun shortcutIdOf(intent: Intent?): String? {
            if (intent == null || intent.action != Intent.ACTION_MAIN) return null
            if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
            val data = intent.data ?: return null
            if (data.scheme != SCHEME || data.host != HOST) return null
            return data.lastPathSegment?.takeIf { it.isNotEmpty() }
        }
    }

    private var channel: MethodChannel? = null

    /** The shortcut the activity was started with (or got before Dart listened), until Dart takes it. */
    private var pending: String? = null

    /** Whether Dart asked for the initial shortcut: from then on it listens to [ON_SHORTCUT]. */
    private var dartListening = false

    fun onCreate(intent: Intent?, savedInstanceState: Bundle?) {
        if (savedInstanceState == null) {
            pending = shortcutIdOf(intent)
        }
    }

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                if (call.method == GET_INITIAL_SHORTCUT) {
                    dartListening = true
                    result.success(pending)
                    pending = null
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    fun onNewIntent(intent: Intent) {
        val id = shortcutIdOf(intent) ?: return
        val channel = channel
        if (channel == null || !dartListening) {
            pending = id
        } else {
            channel.invokeMethod(ON_SHORTCUT, id)
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        dartListening = false
    }
}
