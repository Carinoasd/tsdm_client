package kzs.th000.tsdm_client

import android.content.res.Configuration
import android.os.Build
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import io.flutter.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class MainActivity: FlutterActivity() {
    companion object {
        const val MAIN_CHANNEL = "kzs.th000.tsdm_client/mainChannel"
        const val EXIT_APP = "exitApp"

        const val HTTP_CHANNEL = "kzs.th000.tsdm_client/httpChannel"
        const val HTTP_GET = "get"
        const val HTTP_POST_FORM = "postForm"
        const val HTTP_POST_MULTIPART = "postMultipart"

        /** Window size events sent to Dart, see `lib/utils/window_events.dart` (GitHub #28). */
        const val WINDOW_CHANNEL = "kzs.th000.tsdm_client/windowChannel"
    }

    private var windowChannel: MethodChannel? = null
    private var flutterViewWatched = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MAIN_CHANNEL)
            .setMethodCallHandler{ call, result -> handleMainChannelCall(call, result) }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HTTP_CHANNEL)
            .setMethodCallHandler{ call, result -> handleHttpChannelCall(call, result) }
        windowChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WINDOW_CHANNEL)
    }

    override fun onStart() {
        super.onStart()
        watchFlutterView()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        sendWindowEvent("configurationChanged", describe(newConfig))
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
        val flutterView = findViewById<View>(FLUTTER_VIEW_ID) ?: return
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

    private fun handleMainChannelCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == EXIT_APP) {
            moveTaskToBack(true)
            result.success(true)
        } else {
            result.notImplemented()
        }
    }

    private fun handleHttpChannelCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            HTTP_GET -> {
                val url = call.argument<String>("url")!!
                val headers = call.argument<HashMap<String, String>>("headers")!!
                CoroutineScope(Dispatchers.IO + SupervisorJob()).launch {
                    try {
                        val resp = HttpClient.get(url, headers)
                        val statusCode = resp.code
                        val headers = HashMap(resp.headers.toMultimap())
                        val body = resp.body.bytes()
                        val isRedirect = resp.isRedirect
                        result.success(buildResponse(statusCode, headers, body, isRedirect))
                    } catch (e: Exception) {
                        Log.e("KT_HTTP_ERROR", "failed to get: ${e.message ?: "unknown error"}")
                        result.error("KT_HTTP_ERROR", "failed to perform http GET",e.message ?: "unknown error")
                    }
                }
            }
            HTTP_POST_FORM -> {
                val url = call.argument<String>("url")!!
                val headers = call.argument<HashMap<String, String>>("headers")!!
                val body = call.argument<HashMap<String, String>>("body")!!
                CoroutineScope(Dispatchers.IO + SupervisorJob()).launch {
                    try {
                        val resp = HttpClient.postForm(url, headers, body)
                        val statusCode = resp.code
                        val headers = HashMap(resp.headers.toMultimap())
                        val body = resp.body.bytes()
                        val isRedirect = resp.isRedirect
                        result.success(buildResponse(statusCode, headers, body, isRedirect))
                    } catch (e: Exception) {
                        Log.e("KT_HTTP_ERROR", "failed to post form: ${e.message ?: "unknown error"}")
                        result.error("KT_HTTP_ERROR", "failed to perform http POST form",e.message ?: "unknown error")
                    }
                }
            }
            HTTP_POST_MULTIPART -> {
                val url = call.argument<String>("url")!!
                val headers = call.argument<HashMap<String, String>>("headers")!!
                val body = call.argument<HashMap<String, String>>("body")!!
                CoroutineScope(Dispatchers.IO + SupervisorJob()).launch {
                    try {
                        val resp = HttpClient.postMultipart(url, headers, body)
                        val statusCode = resp.code
                        val headers = HashMap(resp.headers.toMultimap())
                        val body = resp.body.bytes()
                        val isRedirect = resp.isRedirect
                        result.success(buildResponse(statusCode, headers, body, isRedirect))
                    } catch (e: Exception) {
                        Log.e("KT_HTTP_ERROR", "failed to post multipart: ${e.message ?: "unknown error"}")
                        result.error("KT_HTTP_ERROR", "failed to perform http POST multipart",e.message ?: "unknown error")
                    }
                }

            }
            else -> {
                result.notImplemented()
            }
        }
    }
}
