package kzs.th000.tsdm_client

import android.content.Intent
import android.os.Bundle
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The launcher shortcuts of the app icon (`res/xml/shortcuts.xml`) and the forums and threads pinned to the home screen
 * ([PinnedShortcuts], `forum-<fid>`, `thread-<tid>`): each starts [ShortcutActivity], which starts
 * [MainActivityImpl] with `tsdm://shortcut/<id>` as data and [ShortcutKey]; the id is handed to Dart, which navigates.
 * The same intent without the key (another app starting the exported activity) is handed over as the link: Dart then
 * only opens the page ([shortcutIdOf]).
 *
 * A cold start keeps the id until Dart asks for it ([GET_INITIAL_SHORTCUT]); an activity already running gets the
 * intent through `onNewIntent` and the id is pushed to Dart ([ON_SHORTCUT]), once Dart has asked for the initial one
 * (before that Dart is not listening yet and the id is kept for its question instead). An activity recreated by the
 * system (restored state, brought back from the recent apps) ignores the shortcut it was started with, so the
 * shortcut runs once.
 */
class ShortcutsHandler(private val keyOf: () -> String? = { null }) {
    companion object {
        const val CHANNEL = "kzs.th000.tsdm_client/shortcuts"
        const val GET_INITIAL_SHORTCUT = "getInitialShortcut"
        const val ON_SHORTCUT = "onShortcut"

        private const val SCHEME = "tsdm"
        private const val HOST = "shortcut"

        /**
         * The shortcut id of the `ACTION_MAIN` [intent] with `tsdm://shortcut/<id>` as data, null for any other intent
         * and for a relaunch from the recent apps.
         */
        fun idOfData(intent: Intent?): String? {
            if (intent == null || intent.action != Intent.ACTION_MAIN) return null
            if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
            val data = intent.data ?: return null
            if (data.scheme != SCHEME || data.host != HOST) return null
            return data.lastPathSegment?.takeIf { it.isNotEmpty() }
        }

        /**
         * What [intent] hands to Dart: the shortcut's id when the app's own shortcut sent it (it carries [key], see
         * [ShortcutKey]: a launcher shortcut through [ShortcutActivity], a tap on the widget), its `tsdm://shortcut/<id>`
         * link when another app did (Dart then only opens the page, `decideAppShortcut`), null when it is no shortcut.
         */
        fun shortcutIdOf(intent: Intent?, key: String?): String? {
            val id = idOfData(intent) ?: return null
            val sent = intent?.getStringExtra(ShortcutKey.EXTRA)
            return if (key != null && key.isNotEmpty() && sent == key) id else "$SCHEME://$HOST/$id"
        }
    }

    private var channel: MethodChannel? = null

    /** The shortcut the activity was started with (or got before Dart listened), until Dart takes it. */
    private var pending: String? = null

    /** Whether Dart asked for the initial shortcut: from then on it listens to [ON_SHORTCUT]. */
    private var dartListening = false

    fun onCreate(intent: Intent?, savedInstanceState: Bundle?) {
        if (savedInstanceState == null) {
            pending = shortcutIdOf(intent, keyOf())
        }
    }

    /**
     * Listen on [messenger]. [listening]: Dart runs since an activity before and listens already (it asks for the
     * initial shortcut once, at its start): the shortcut this activity was launched with is pushed by [pushPending].
     * [pins] answers Dart's questions to pin a forum or a thread to the home screen ([PinnedShortcuts]).
     */
    fun attach(messenger: BinaryMessenger, listening: Boolean = false, pins: PinnedShortcuts? = null) {
        dartListening = listening
        channel = MethodChannel(messenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                if (call.method == GET_INITIAL_SHORTCUT) {
                    dartListening = true
                    result.success(pending)
                    pending = null
                } else if (pins == null || !pins.handle(call, result)) {
                    result.notImplemented()
                }
            }
        }
    }

    /**
     * Push the shortcut the activity was launched with to a Dart that listens already. A Dart started a moment ago may
     * not: the shortcut is kept for its question then, as at a cold start.
     */
    fun pushPending() {
        val channel = channel ?: return
        if (!dartListening) return
        pending?.let {
            pending = null
            channel.invokeMethod(ON_SHORTCUT, it, object : MethodChannel.Result {
                override fun success(result: Any?) {}
                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
                override fun notImplemented() {
                    dartListening = false
                    if (pending == null) pending = it
                }
            })
        }
    }

    fun onNewIntent(intent: Intent) {
        val id = shortcutIdOf(intent, keyOf()) ?: return
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
