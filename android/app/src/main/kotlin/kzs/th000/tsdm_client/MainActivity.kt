package kzs.th000.tsdm_client

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import io.flutter.Log
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.dexterous.flutterlocalnotifications.FlutterLocalNotificationsPlugin
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import com.ryanheise.audioservice.AudioServicePlugin
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Response
import java.io.ByteArrayOutputStream

// The file keeps its name (tests and the workflow path filters read it); the launcher entries named MainActivity and
// IconDark, IconMono, IconPink are activity-aliases of this class (see the manifest and AppIconSwitcher).
/**
 * A [FlutterFragmentActivity] for the system biometric prompt of the app lock (`local_auth` shows it as a fragment), on
 * the audio service's engine ([AudioServiceFragmentActivity], just_audio_background): the player plays in it with the
 * app in the background.
 */
class MainActivityImpl: AudioServiceFragmentActivity() {
    companion object {
        const val MAIN_CHANNEL = "kzs.th000.tsdm_client/mainChannel"
        const val EXIT_APP = "exitApp"
        const val OPEN_IN_BROWSER = "openInBrowser"
        const val SET_HIGH_REFRESH_RATE = "setHighRefreshRate"
        const val SET_APP_ICON = "setAppIcon"
        const val IS_ACTIVE_NETWORK_METERED = "isActiveNetworkMetered"
        const val DEVICE_NAME = "deviceName"
        const val OPEN_ATTACHMENT = "openAttachment"
        /**
         * Whether the system draws the biometric prompt (Android 9+). Before that androidx.biometric shows its own
         * fingerprint dialog, which needs an AppCompat theme this activity does not have: the app lock offers the PIN
         * only there.
         */
        const val HAS_SYSTEM_BIOMETRIC_PROMPT = "hasSystemBiometricPrompt"
        /** Whether a hardware keyboard is in use, see [HardwareKeyboards]: asked by Dart, and sent to it on changes. */
        const val HAS_HARDWARE_KEYBOARD = "hasHardwareKeyboard"
        const val HARDWARE_KEYBOARD_CHANGED = "hardwareKeyboardChanged"
        /** Dart tells whether the background message service is wanted, see [BackgroundSyncGuard]. */
        const val SET_BACKGROUND_SYNC_GUARD = "setBackgroundSyncGuard"
        /** Sent to Dart with whether the default network is metered, each time it changes. */
        const val NETWORK_METERED_CHANGED = "networkMeteredChanged"

        const val UPDATE_CHANNEL = "kzs.th000.tsdm_client/updateChannel"
        const val INTERACTIVE_HTML_CHANNEL = "kzs.th000.tsdm_client/interactiveHtmlChannel"

        const val HTTP_CHANNEL = "kzs.th000.tsdm_client/httpChannel"
        const val HTTP_GET = "get"
        const val HTTP_POST_FORM = "postForm"
        const val HTTP_POST_MULTIPART = "postMultipart"
        const val HTTP_POST_JSON = "postJson"

        /** Called on Dart while a GET that carried a `progressId` downloads: how much of its body arrived. */
        const val HTTP_PROGRESS = "progress"

        /** Largest buffer allocated up front for a body read with its progress; a larger body grows it as it comes. */
        const val PREALLOCATED_BODY_MAX = 8L * 1024 * 1024

        /** Window size events sent to Dart, see `lib/utils/window_events.dart` (GitHub #28). */
        const val WINDOW_CHANNEL = "kzs.th000.tsdm_client/windowChannel"

        /** Deep link channel to open external tsdm links inside the app. */
        const val DEEP_LINK_CHANNEL = "kzs.th000.tsdm_client/deepLink"
        const val GET_INITIAL_LINK = "getInitialLink"

        /** Whether Dart asked for the highest refresh rate: Dart tells it once, an activity made again keeps it. */
        private var preferHighRefreshRate = false
    }

    private var windowChannel: MethodChannel? = null
    private var httpChannel: MethodChannel? = null
    private var mainChannel: MethodChannel? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var flutterViewWatched = false
    private val updateScope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())
    private var installingUpdate = false

    /** Hold the deep link when app is launched from a link (cold start). */
    private var initialDeepLink: String? = null

    /** The launcher shortcuts of the app icon, see [ShortcutsHandler]. */
    private val shortcuts = ShortcutsHandler()

    /** The home screen widget's state, told by Dart, see [HomeWidgetChannel]. */
    private val homeWidget = HomeWidgetChannel()
    /** The share intent the app was launched with (cold start), read when Dart asks for it, see [ShareIntents]. */
    private var initialShareIntent: Intent? = null
    private var shareChannel: MethodChannel? = null

    /** Dart asked for the initial share: its handler for pushed shares is set, a share can be pushed to it now. */
    private var dartTakesShares = false

    /**
     * The intent this activity was launched with, when it is new: a tap on a local notification among them, see
     * [pushLaunchToRunningDart].
     */
    private var initialLaunchIntent: Intent? = null

    /**
     * Whether the engine ran before this activity was made. The engine is the audio service's (see
     * [provideFlutterEngine]) and outlives the activities, with its Dart:
     *
     * * the task was swiped away from the recents while the background service or the player kept the process, then
     *   the app is opened again;
     * * the audio service was created without an activity and made this engine: bound by the audio service's plugin
     *   of another engine of the process (the background service at boot or after an update, the reply typed in a
     *   notification), or started by a media button. (The Bluetooth stack bound it at boot too, until the service was
     *   no longer exported.)
     *
     * In the first case that Dart asked for its launch link, share, shortcut and notification long ago and will not
     * ask again: what this activity was launched with is pushed to it, see [pushLaunchToRunningDart]. In the second
     * its `main()` waits for this activity (`waitForAndroidActivity` in `lib/utils/android_activity.dart`) and does
     * not listen yet: what it does not take is kept for the questions it asks once it starts.
     */
    private var engineRanBefore = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // Asked before super.onCreate, which makes the engine when there is none (AudioServiceFragmentActivity).
        engineRanBefore = FlutterEngineCache.getInstance().contains(AudioServicePlugin.getFlutterEngineId())
        super.onCreate(savedInstanceState)
        shortcuts.onCreate(intent, savedInstanceState)
        // The intent the activity was created with, only when it is new: the recents replay the launch intent of the
        // task (with FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY), and a recreated process gets it again with its saved state;
        // a link or a share handled before must not open its page or its editor a second time.
        val launch = intent
        val replayed = savedInstanceState != null ||
            launch == null ||
            (launch.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        if (!replayed) {
            // 冷启动时捕获深度链接
            if (launch.action == Intent.ACTION_VIEW) {
                initialDeepLink = launch.dataString
            }
            if (ShareIntents.isShare(launch)) {
                initialShareIntent = launch
            }
            initialLaunchIntent = launch
        }
        // A FlutterFragmentActivity configures its engine when its fragment attaches, after onCreate: the launch read
        // above is pushed at the end of configureFlutterEngine. Reading `flutterEngine` here would throw: the
        // fragment's delegate does not exist yet.
    }

    /** The deep link channel of the engine, set in [configureFlutterEngine]; null until the fragment attached. */
    private var deepLinkChannel: MethodChannel? = null

    /** The audio service's engine (just_audio_background): the player plays in it with the app in the background. */
    override fun provideFlutterEngine(context: Context): FlutterEngine = AudioServicePlugin.getFlutterEngine(context)

    /**
     * The app routes links itself ([onNewIntent], the deep link channel): the engine must never push them to go_router,
     * whatever component was launched. The manifest says the same (`flutter_deeplinking_enabled`), but that meta-data is
     * read from the launched component, and a launcher alias missing it once made the engine take the links.
     */
    override fun shouldHandleDeeplinking(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // See [engineRanBefore].
        val dartRunning = engineRanBefore
        mainChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MAIN_CHANNEL).also {
            it.setMethodCallHandler { call, result -> handleMainChannelCall(call, result) }
        }
        watchNetwork()
        httpChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HTTP_CHANNEL)
            .apply { setMethodCallHandler{ call, result -> handleHttpChannelCall(call, result) } }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL)
            .setMethodCallHandler { call, result -> handleUpdateChannelCall(call, result) }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INTERACTIVE_HTML_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "openHtml") {
                    result.notImplemented()
                } else {
                    try {
                        startActivity(InteractiveHtmlActivity.intent(this,
                            call.argument<Any>("html") as? String,
                            call.argument<Any>("sourceUrl") as? String,
                            call.argument<Any>("accountScope") as? String,
                            call.argument<Any>("postId") as? String,
                            call.argument<Any>("locale") as? String,
                            call.argument<Any>("labels") as? Map<*, *>,
                        ))
                        result.success(true)
                    } catch (error: InteractiveHtmlPolicy.Failure) {
                        result.error(error.code, error.message, null)
                    } catch (_: Exception) {
                        result.error("interactive_html_unavailable", "Unable to open interactive content on this device.", null)
                    }
                }
            }
        windowChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WINDOW_CHANNEL)
        shortcuts.attach(flutterEngine.dartExecutor.binaryMessenger, listening = dartRunning)
        homeWidget.attach(flutterEngine.dartExecutor.binaryMessenger, this)

        // 处理 Flutter 端对深度链接的查询
        deepLinkChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEEP_LINK_CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                if (call.method == GET_INITIAL_LINK) {
                    result.success(initialDeepLink)
                    initialDeepLink = null // 取过一次就清空，避免重复跳转
                } else {
                    result.notImplemented()
                }
            }
        }

        // Content other apps shared to this one: asked once at a cold start, pushed on a warm one (onNewIntent).
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ShareIntents.CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                if (call.method != ShareIntents.GET_INITIAL_SHARE) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                dartTakesShares = true
                val pending = initialShareIntent
                initialShareIntent = null // Handed over once; a configuration change must not post it twice.
                updateScope.launch {
                    if (pending == null) {
                        // Copies left by a run that was killed before uploading them.
                        withContext(Dispatchers.IO) { ShareIntents.removeStale(applicationContext) }
                        result.success(null)
                    } else {
                        result.success(readShare(pending))
                    }
                }
            }
        }
        // The launch intent was read in onCreate, before this ran (see there): give it to the Dart already running.
        // (A recreated activity, with a saved state, attaches its fragment inside super.onCreate, so this runs before
        // onCreate read the intent: that launch is a replayed one, nothing of it is pushed.)
        if (dartRunning) {
            pushLaunchToRunningDart(flutterEngine)
        } else {
            // A Dart that starts now reads the tap on a notification itself (getNotificationAppLaunchDetails).
            initialLaunchIntent = null
        }
    }

    /**
     * The link and the share this activity was launched with, pushed to a Dart that runs since before this activity
     * (see [engineRanBefore]) as when they come to a running activity ([onNewIntent]), with the shortcut and the tap on
     * a local notification.
     *
     * A Dart started a moment ago may not listen yet: what it does not take is kept for its question, as at a cold
     * start (its `main()` asks once the app is built, and this activity answers by then).
     */
    private fun pushLaunchToRunningDart(flutterEngine: FlutterEngine) {
        // A tap on a local notification that made this activity: flutter_local_notifications tells Dart of a tap from
        // onNewIntent alone, and keeps the one an activity was launched with for Dart's question at its start
        // (getNotificationAppLaunchDetails), which this Dart asked long ago: the tap brought the app to the front and
        // opened nothing, and the text of a reply that was not sent, kept as a draft by that tap, was lost with its
        // notification. Handed to the plugin as the new intent it is; the plugin takes its own intents only. (A Dart
        // that does not listen yet reads the launch details after this: the plugin has this activity by now.)
        initialLaunchIntent?.let { launch ->
            initialLaunchIntent = null
            try {
                val plugin = flutterEngine.plugins.get(FlutterLocalNotificationsPlugin::class.java)
                (plugin as? FlutterLocalNotificationsPlugin)?.onNewIntent(launch)
            } catch (e: Exception) {
                Log.e("NOTIFICATION_TAP", "launch intent not handed to the notification plugin: ${e.message}")
            }
        }
        dartTakesShares = true
        shortcuts.pushPending()
        val links = deepLinkChannel
        if (links != null) {
            initialDeepLink?.let {
                initialDeepLink = null
                links.invokeMethod("onDeepLink", it, unheard { if (initialDeepLink == null) initialDeepLink = it })
            }
        }
        initialShareIntent?.let { pending ->
            initialShareIntent = null
            val channel = shareChannel ?: return@let
            updateScope.launch {
                val payload = readShare(pending) ?: return@launch
                channel.invokeMethod(ShareIntents.ON_SHARE, payload, shareUnheard(pending))
            }
        }
    }

    /**
     * The result of pushing the share of [intent] to Dart: when Dart does not listen (yet), the share is kept for its
     * question, unless a newer one is kept already. It is read again then: the copies made for the push are cleaned
     * up a day later.
     */
    private fun shareUnheard(intent: Intent) = unheard {
        dartTakesShares = false
        if (initialShareIntent == null) initialShareIntent = intent
    }

    /** The result of a push to Dart that only tells when Dart does not listen to the channel (yet): [kept] runs then. */
    private fun unheard(kept: () -> Unit) = object : MethodChannel.Result {
        override fun success(result: Any?) {}
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
        override fun notImplemented() = kept()
    }

    /** The shared content of [intent] with its images copied into the cache (file IO off the main thread). */
    private suspend fun readShare(intent: Intent): Map<String, Any?>? = withContext(Dispatchers.IO) {
        try {
            ShareIntents.read(applicationContext, intent)
        } catch (_: Exception) {
            null
        }
    }

    /** 热启动（App 在后台）时接收新的深度链接并推送给 Flutter */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        shortcuts.onNewIntent(intent)
        if (intent.action == Intent.ACTION_VIEW) {
            val link = intent.dataString
            // Before the fragment attached there is no channel (and reading `flutterEngine` would throw): kept for
            // Dart's getInitialLink, like a cold start's.
            val channel = deepLinkChannel
            if (link != null) {
                if (channel == null) initialDeepLink = link else channel.invokeMethod("onDeepLink", link)
            }
        }
        if (ShareIntents.isShare(intent)) {
            val channel = shareChannel
            if (channel == null || !dartTakesShares) {
                // Dart is not listening yet: keep it for its getInitialShare. Only the latest is kept: a second share
                // within the seconds before Dart asks replaces the first (its images are cleaned up a day later).
                initialShareIntent = intent
                return
            }
            updateScope.launch {
                val payload = readShare(intent) ?: return@launch
                channel.invokeMethod(ShareIntents.ON_SHARE, payload, shareUnheard(intent))
            }
        }
    }

    override fun onStart() {
        super.onStart()
        watchFlutterView()
    }

    override fun onResume() {
        super.onResume()
        // The display can change while in background (folding, an external screen), so pick the mode again.
        if (preferHighRefreshRate) applyRefreshRate()
        // The background message service went while the process lived on: started again now that the app is in front.
        BackgroundSyncGuard.onActivityResumed(applicationContext)
        // A keyboard attached or removed while another activity was in front (the interactive viewer), or while this
        // one did not exist (a task swiped away and opened again on the same Dart).
        notifyHardwareKeyboard(resources.configuration)
    }

    override fun onDestroy() {
        networkCallback?.let {
            try {
                (getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager)?.unregisterNetworkCallback(it)
            } catch (_: Exception) {
            }
        }
        networkCallback = null
        updateScope.cancel()
        shortcuts.detach()
        homeWidget.detach()
        super.onDestroy()
    }

    private fun handleUpdateChannelCall(call: MethodCall, result: MethodChannel.Result) {
        val installer = UpdateInstaller(this)
        if (call.method == "installUpdate" && installingUpdate) {
            result.error("update_install_in_progress", "An update installation request is already in progress.", null)
            return
        }
        updateScope.launch {
            try {
                when (call.method) {
                    "getUpdateDirectory" -> result.success(withContext(Dispatchers.IO) { installer.updateDirectory().path })
                    "canInstallPackages" -> result.success(installer.canInstallPackages())
                    "openInstallPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startActivity(installer.permissionIntent())
                        }
                        result.success(true)
                    }
                    "installUpdate" -> {
                        installingUpdate = true
                        val path = call.argument<Any>("path") as? String
                        val version = call.argument<Any>("version") as? String
                        val versionCode = when (val value = call.argument<Any>("versionCode")) {
                            is Int -> value.toLong()
                            is Long -> value
                            else -> null
                        }
                        if (path.isNullOrBlank() || version.isNullOrBlank() || versionCode == null || versionCode <= 0) {
                            throw UpdateInstaller.Failure("invalid_update_arguments", "The update request is incomplete.")
                        }
                        if (!installer.canInstallPackages()) {
                            throw UpdateInstaller.Failure("install_permission_required", "Allow this app to install updates in system settings.")
                        }
                        val intent = withContext(Dispatchers.IO) { installer.prepareInstall(path, version, versionCode) }
                        // Permission can change while a large APK is being checked.
                        if (!installer.canInstallPackages()) {
                            throw UpdateInstaller.Failure("install_permission_required", "Allow this app to install updates in system settings.")
                        }
                        startActivity(intent)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: UpdateInstaller.Failure) {
                result.error(error.code, error.message, null)
            } catch (_: ActivityNotFoundException) {
                val code = if (call.method == "openInstallPermission") "install_permission_unavailable" else "installer_unavailable"
                result.error(code, "The required system screen is unavailable.", null)
            } catch (_: SecurityException) {
                result.error("installer_not_allowed", "The system did not allow this update request.", null)
            } catch (_: Exception) {
                result.error("invalid_update_apk", "The update could not be verified or opened.", null)
            } finally {
                if (call.method == "installUpdate") installingUpdate = false
            }
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        sendWindowEvent("configurationChanged", describe(newConfig))
        notifyHardwareKeyboard(newConfig)
    }

    /** Tell Dart whether a hardware keyboard is in use; Dart keeps the last value and ignores a repeated one. */
    private fun notifyHardwareKeyboard(config: Configuration) {
        mainChannel?.invokeMethod(HARDWARE_KEYBOARD_CHANGED, HardwareKeyboards.inUse(config))
    }

    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean, newConfig: Configuration) {
        super.onMultiWindowModeChanged(isInMultiWindowMode, newConfig)
        sendWindowEvent("multiWindowModeChanged", describe(newConfig) + ("multiWindow" to isInMultiWindowMode))
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        sendWindowEvent(
            "pictureInPictureModeChanged",
            describe(newConfig) + ("pictureInPicture" to isInPictureInPictureMode),
        )
    }

    /**
     * Report the layouts of the FlutterView and the size changes of its render surface (GitHub #28).
     *
     * Together with the configuration callbacks above and the metrics logged on the Dart side, an exported log
     * shows which layer stopped following a window resize: the system, this view, the engine or the framework.
     * Listening only; nothing here changes the layout.
     */
    private fun watchFlutterView() {
        if (flutterViewWatched) {
            return
        }
        val flutterView = findViewById<View>(FlutterFragment.FLUTTER_VIEW_ID) ?: return
        flutterViewWatched = true
        flutterView.addOnLayoutChangeListener { view, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom ->
            val width = right - left
            val height = bottom - top
            if (width != oldRight - oldLeft || height != oldBottom - oldTop) {
                sendWindowEvent(
                    "flutterViewLayout",
                    mapOf("width" to width, "height" to height, "visibility" to view.visibility),
                )
            }
        }
        val group = flutterView as? ViewGroup ?: return
        val surface = (0 until group.childCount).map(group::getChildAt).firstOrNull { it is SurfaceView } as? SurfaceView
        surface?.holder?.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                sendWindowEvent("surfaceCreated", emptyMap())
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                sendWindowEvent("surfaceChanged", mapOf("width" to width, "height" to height))
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                sendWindowEvent("surfaceDestroyed", emptyMap())
            }
        })
    }

    private fun describe(config: Configuration): Map<String, Any?> = mapOf(
        "screenWidthDp" to config.screenWidthDp,
        "screenHeightDp" to config.screenHeightDp,
        "orientation" to config.orientation,
        "densityDpi" to config.densityDpi,
    )

    private fun sendWindowEvent(name: String, args: Map<String, Any?>) {
        val decor = window?.decorView
        val metrics = resources.displayMetrics
        val payload = HashMap<String, Any?>(args)
        payload["decorWidth"] = decor?.width
        payload["decorHeight"] = decor?.height
        payload["displayWidth"] = metrics.widthPixels
        payload["displayHeight"] = metrics.heightPixels
        if (!payload.containsKey("multiWindow") && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            payload["multiWindow"] = isInMultiWindowMode
        }
        windowChannel?.invokeMethod(name, payload)
    }

    /** Tell Dart whether the default network is metered each time it changes ("on Wi-Fi only" settings). */
    private fun watchNetwork() {
        if (networkCallback != null || Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = notifyNetworkMetered()
            override fun onLost(network: Network) = notifyNetworkMetered()
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) =
                notifyNetworkMetered()
        }
        try {
            manager.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        } catch (_: Exception) {
            // Without the callback Dart asks again on its own (foreground, a few seconds old).
        }
    }

    private fun notifyNetworkMetered() {
        val metered = (getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager)?.isActiveNetworkMetered ?: true
        runOnUiThread { mainChannel?.invokeMethod(NETWORK_METERED_CHANGED, metered) }
    }

    private fun handleMainChannelCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            EXIT_APP -> {
                moveTaskToBack(true)
                result.success(true)
            }
            OPEN_IN_BROWSER -> openInBrowser(call.argument<Any>("url") as? String, result)
            SET_HIGH_REFRESH_RATE -> {
                preferHighRefreshRate = call.argument<Any>("enable") as? Boolean ?: false
                result.success(applyRefreshRate())
            }
            SET_APP_ICON -> {
                val name = call.argument<Any>("name") as? String
                if (name != null && AppIconSwitcher.apply(applicationContext, name)) {
                    result.success(true)
                } else {
                    result.error("unknown_icon", "No such app icon: $name", null)
                }
            }
            // Whether large downloads should wait (the thread list thumbnails "on Wi-Fi only"): the system's own answer,
            // true without a network. Needs ACCESS_NETWORK_STATE, which the manifest has.
            IS_ACTIVE_NETWORK_METERED -> {
                val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                result.success(manager?.isActiveNetworkMetered ?: true)
            }
            // The name the forum's list of login devices shows: "Google Pixel 7", or the model alone when it names the
            // maker already ("SM-S9180" is not, "Xiaomi 14" is).
            DEVICE_NAME -> {
                val maker = Build.MANUFACTURER.orEmpty().trim()
                val model = Build.MODEL.orEmpty().trim()
                result.success(if (maker.isEmpty() || model.startsWith(maker, ignoreCase = true)) model else "$maker $model")
            }
            HAS_SYSTEM_BIOMETRIC_PROMPT -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            HAS_HARDWARE_KEYBOARD -> result.success(HardwareKeyboards.inUse(resources.configuration))
            SET_BACKGROUND_SYNC_GUARD -> {
                val wanted = call.argument<Any>("wanted") as? Boolean
                if (wanted == null) {
                    result.error("invalid_arguments", "wanted is required", null)
                } else {
                    BackgroundSyncGuard.setWanted(applicationContext, wanted, call.argument<Any>("title") as? String)
                    result.success(true)
                }
            }
            OPEN_ATTACHMENT -> result.success(
                AttachmentFiles.open(this, call.argument<Any>("path") as? String) { startActivity(it) },
            )
            else -> result.notImplemented()
        }
    }

    /**
     * Prefer the display mode with the highest refresh rate at the current resolution, or clear the preference
     * (GitHub #182).
     *
     * Some vendor systems keep apps that set no preferred mode at 60Hz on 90/120Hz screens. Only modes with the
     * current resolution are considered so the screen never switches resolution. Returns the refresh rate of the
     * preferred mode, 0 when nothing is preferred.
     */
    private fun applyRefreshRate(): Double {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return 0.0
        @Suppress("DEPRECATION")
        val display = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display else windowManager.defaultDisplay)
            ?: return 0.0
        val mode = if (preferHighRefreshRate) {
            val current = display.mode
            display.supportedModes
                .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
                .maxByOrNull { it.refreshRate }
        } else {
            null
        }
        val attributes = window.attributes
        val modeId = mode?.modeId ?: 0
        if (attributes.preferredDisplayModeId != modeId) {
            attributes.preferredDisplayModeId = modeId
            window.attributes = attributes
        }
        return mode?.refreshRate?.toDouble() ?: 0.0
    }

    /** Forward native launch failures to the exportable Flutter log, without including the URL or its parameters. */
    private fun openInBrowser(url: String?, result: MethodChannel.Result) {
        val outcome = BrowserIntents.launch(url) { startActivity(it) }
        if (outcome == BrowserIntents.LaunchResult.STARTED) {
            result.success(true)
        } else {
            result.error(outcome.errorCode!!, outcome.message, mapOf(
                "strategy" to BrowserIntents.STRATEGY,
                "sdk" to Build.VERSION.SDK_INT,
                "manufacturer" to Build.MANUFACTURER,
                "model" to Build.MODEL,
            ))
        }
    }

    /**
     * The body of [resp], read in pieces with Dart told how much of it arrived (at most every 100 ms): the GET carried
     * a `progressId`, an image whose loading shows its progress. `total` is -1 when the server did not tell the size.
     */
    private fun readReportingProgress(resp: Response, id: Int): ByteArray {
        val body = resp.body
        val total = body.contentLength()
        val out = ByteArrayOutputStream(if (total in 1..PREALLOCATED_BODY_MAX) total.toInt() else 256 * 1024)
        val buffer = ByteArray(16 * 1024)
        var received = 0L
        var reportedAt = 0L
        body.byteStream().use { input ->
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                out.write(buffer, 0, count)
                received += count
                val now = SystemClock.uptimeMillis()
                if (now - reportedAt >= 100) {
                    reportedAt = now
                    val args = mapOf("id" to id, "received" to received, "total" to total)
                    runOnUiThread { httpChannel?.invokeMethod(HTTP_PROGRESS, args) }
                }
            }
        }
        return out.toByteArray()
    }

    private fun handleHttpChannelCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            HTTP_GET -> {
                val url = call.argument<String>("url")!!
                val headers = call.argument<HashMap<String, String>>("headers")!!
                val singleAttempt = call.argument<Boolean>("singleAttempt") ?: false
                val progressId = call.argument<Int>("progressId")
                CoroutineScope(Dispatchers.IO + SupervisorJob()).launch {
                    try {
                        val resp = HttpClient.get(url, headers, singleAttempt = singleAttempt)
                        val statusCode = resp.code
                        val headers = HashMap(resp.headers.toMultimap())
                        val body = if (progressId == null) resp.body.bytes() else readReportingProgress(resp, progressId)
                        val isRedirect = resp.isRedirect
                        result.success(buildResponse(statusCode, headers, body, isRedirect))
                    } catch (e: Exception) {
                        Log.e("KT_HTTP_ERROR", "failed to get: ${e.message ?: "unknown error"}")
                        result.error(HttpClient.errorCode(e), "failed to perform http GET",e.message ?: "unknown error")
                    }
                }
            }
            HTTP_POST_FORM -> {
                val url = call.argument<String>("url")!!
                val headers = call.argument<HashMap<String, String>>("headers")!!
                val body = call.argument<HashMap<String, String>>("body")!!
                val singleAttempt = call.argument<Boolean>("singleAttempt") ?: false
                CoroutineScope(Dispatchers.IO + SupervisorJob()).launch {
                    try {
                        val resp = HttpClient.postForm(url, headers, body, singleAttempt = singleAttempt)
                        val statusCode = resp.code
                        val headers = HashMap(resp.headers.toMultimap())
                        val body = resp.body.bytes()
                        val isRedirect = resp.isRedirect
                        result.success(buildResponse(statusCode, headers, body, isRedirect))
                    } catch (e: Exception) {
                        Log.e("KT_HTTP_ERROR", "failed to post form: ${e.message ?: "unknown error"}")
                        result.error(HttpClient.errorCode(e), "failed to perform http POST form", e.message ?: "unknown error")
                    }
                }
            }
            HTTP_POST_MULTIPART -> {
                val url = call.argument<String>("url")!!
                val headers = call.argument<HashMap<String, String>>("headers")!!
                // Strings, and maps describing a file part (see HttpClient.postMultipart).
                val body = call.argument<HashMap<String, Any?>>("body")!!
                val singleAttempt = call.argument<Boolean>("singleAttempt") ?: false
                CoroutineScope(Dispatchers.IO + SupervisorJob()).launch {
                    try {
                        val resp = HttpClient.postMultipart(url, headers, body, singleAttempt = singleAttempt)
                        val statusCode = resp.code
                        val headers = HashMap(resp.headers.toMultimap())
                        val body = resp.body.bytes()
                        val isRedirect = resp.isRedirect
                        result.success(buildResponse(statusCode, headers, body, isRedirect))
                    } catch (e: Exception) {
                        Log.e("KT_HTTP_ERROR", "failed to post multipart: ${e.message ?: "unknown error"}")
                        result.error(HttpClient.errorCode(e), "failed to perform http POST multipart", e.message ?: "unknown error")
                    }
                }

            }
            HTTP_POST_JSON -> {
                val url = call.argument<String>("url")!!
                val headers = call.argument<HashMap<String, String>>("headers")!!
                val body = call.argument<String>("body")!!
                val singleAttempt = call.argument<Boolean>("singleAttempt") ?: false
                CoroutineScope(Dispatchers.IO + SupervisorJob()).launch {
                    try {
                        val resp = HttpClient.postJson(url, headers, body, singleAttempt = singleAttempt)
                        val statusCode = resp.code
                        val headers = HashMap(resp.headers.toMultimap())
                        val body = resp.body.bytes()
                        val isRedirect = resp.isRedirect
                        result.success(buildResponse(statusCode, headers, body, isRedirect))
                    } catch (e: Exception) {
                        Log.e("KT_HTTP_ERROR", "failed to post json: ${e.message ?: "unknown error"}")
                        result.error(HttpClient.errorCode(e), "failed to perform http POST json", e.message ?: "unknown error")
                    }
                }
            }
            else -> {
                result.notImplemented()
            }
        }
    }
}
