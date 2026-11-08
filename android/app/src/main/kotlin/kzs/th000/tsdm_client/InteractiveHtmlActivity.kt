package kzs.th000.tsdm_client

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.net.Uri
import android.net.http.SslError
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.webkit.ClientCertRequest
import android.webkit.CookieManager
import android.webkit.GeolocationPermissions
import android.webkit.HttpAuthHandler
import android.webkit.JsPromptResult
import android.webkit.JsResult
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.util.Locale

/** Runs only the selected post fragment, never a logged-in forum page. No JavascriptInterface is installed. */
class InteractiveHtmlActivity : Activity() {
    private lateinit var content: InteractiveHtmlPolicy.Content
    private lateinit var body: LinearLayout
    private lateinit var status: TextView
    private lateinit var titleView: TextView
    private var webView: WebView? = null
    private var images: InteractiveHtmlImages? = null
    private var pageDialog: AlertDialog? = null
    private val labels by lazy {
        Labels.resolve(labelMap(intent.getBundleExtra(EXTRA_LABELS)), intent.getStringExtra(EXTRA_LOCALE))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        content = try {
            InteractiveHtmlPolicy.validate(
                intent.getStringExtra(EXTRA_HTML), intent.getStringExtra(EXTRA_SOURCE_URL),
                intent.getStringExtra(EXTRA_ACCOUNT_SCOPE), intent.getStringExtra(EXTRA_POST_ID),
            )
        } catch (_: Exception) {
            Toast.makeText(this, labels.openFailed, Toast.LENGTH_LONG).show()
            finish()
            return
        }
        buildChrome()
        try {
            val viewer = WebView(this).also { webView = it }
            viewer.tag = "interactive_html_webview"
            configure(viewer)
            body.addView(viewer, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
            images = InteractiveHtmlImages(content.imageUrls)
            viewer.webViewClient = contentClient()
            viewer.webChromeClient = chromeClient()
            viewer.setDownloadListener { _, _, _, _, _ -> showMessage(labels.downloadInOriginal) }
            viewer.loadUrl(content.documentUrl)
        } catch (_: Exception) {
            showFailure()
        }
    }

    /**
     * Rotation, a window resize and a dark mode switch are handled here instead of recreating the Activity: a new
     * Activity would load the post again and lose what the reader did in it (quiz progress, filled fields).
     */
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (!::status.isInitialized) return
        applyColors(newConfig)
        // The new orientation or size brings new insets; the listener set in buildChrome pads for them.
        ViewCompat.requestApplyInsets(body)
    }

    private fun applyColors(configuration: Configuration) {
        val dark = isDark(configuration)
        val foreground = if (dark) Color.WHITE else Color.rgb(28, 30, 34)
        body.setBackgroundColor(if (dark) Color.rgb(25, 27, 31) else Color.WHITE)
        titleView.setTextColor(foreground)
        status.setTextColor(foreground)
        WindowCompat.getInsetsController(window, body).apply {
            isAppearanceLightStatusBars = !dark
            isAppearanceLightNavigationBars = !dark
        }
    }

    @Suppress("DEPRECATION")
    private fun buildChrome() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        // Draw the background under a landscape notch too; the insets below keep the controls and page clear of it.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode = android.view.WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        ViewCompat.setOnApplyWindowInsetsListener(body) { view, insets ->
            val safe = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout() or WindowInsetsCompat.Type.ime())
            view.setPadding(safe.left, safe.top, safe.right, safe.bottom)
            WindowInsetsCompat.CONSUMED
        }
        val toolbar = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        toolbar.addView(Button(this).apply {
            text = labels.back
            contentDescription = text
            setOnClickListener { finish() }
        })
        titleView = TextView(this).apply {
            text = labels.title
            textSize = 18f
            gravity = android.view.Gravity.CENTER_VERTICAL
        }
        toolbar.addView(titleView, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
        toolbar.addView(Button(this).apply {
            text = labels.original
            contentDescription = labels.originalDescription
            setOnClickListener { openBrowser(content.sourceUrl) }
        })
        body.addView(toolbar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        status = TextView(this).apply {
            text = labels.loading
            setPadding(dp(16), dp(12), dp(16), dp(12))
        }
        body.addView(status)
        setContentView(body)
        applyColors(resources.configuration)
        ViewCompat.requestApplyInsets(body)
    }

    @Suppress("DEPRECATION", "SetJavaScriptEnabled")
    private fun configure(view: WebView) {
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            allowFileAccessFromFileURLs = false
            allowUniversalAccessFromFileURLs = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(true)
            setGeolocationEnabled(false)
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            blockNetworkLoads = true
            cacheMode = WebSettings.LOAD_NO_CACHE
            mediaPlaybackRequiresUserGesture = true
            saveFormData = false
            useWideViewPort = true
            loadWithOverviewMode = true
            builtInZoomControls = true
            displayZoomControls = false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) safeBrowsingEnabled = true
        }
        // This setting is per-WebView; never change global CookieManager acceptance or forum cookies.
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            view.importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        }
    }

    private fun contentClient() = object : WebViewClient() {
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
            if (request.method != "GET") return InteractiveHtmlImages.blocked()
            if (request.isForMainFrame && request.url.toString() == content.documentUrl) {
                return WebResourceResponse("text/html", "UTF-8", 200, "OK", InteractiveHtmlPolicy.headers(content),
                    ByteArrayInputStream(InteractiveHtmlPolicy.document(content).toByteArray(Charsets.UTF_8)))
            }
            if (request.isForMainFrame) return InteractiveHtmlImages.blocked()
            return images?.load(request.url.toString()) ?: InteractiveHtmlImages.blocked()
        }

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val raw = request.url.toString()
            if (!request.isForMainFrame || request.method != "GET") return true
            InteractiveHtmlPolicy.fragment(content, raw)?.let { fragment ->
                view.evaluateJavascript("(function(){try{var id=decodeURIComponent(${JSONObject.quote(fragment)});var e=document.getElementById(id)||document.getElementsByName(id)[0];if(e)e.scrollIntoView();else if(!id)window.scrollTo(0,0);}catch(e){}})();", null)
                return true
            }
            if (raw == content.documentUrl) return false
            if (!request.hasGesture() || request.isRedirect) return true
            val url = InteractiveHtmlPolicy.safeLink(raw) ?: return true
            if (InteractiveHtmlPolicy.isForumUrl(url)) {
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url.toString()))
                        .setClassName(packageName, "kzs.th000.tsdm_client.MainActivityImpl")
                        .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
                    finish()
                } catch (_: Exception) { showMessage(labels.linkFailed) }
            } else openBrowser(url.toString())
            return true
        }

        @Deprecated("Only the request overload provides proof of a user gesture")
        override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean = true

        override fun onPageFinished(view: WebView, url: String) {
            if (url == content.documentUrl) status.visibility = View.GONE
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            if (request.isForMainFrame) showFailure()
        }

        override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) { handler.cancel() }
        override fun onReceivedHttpAuthRequest(view: WebView, handler: HttpAuthHandler, host: String, realm: String) { handler.cancel() }
        override fun onReceivedClientCertRequest(view: WebView, request: ClientCertRequest) { request.cancel() }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            releaseWebView()
            showFailure()
            return true
        }
    }

    private fun chromeClient() = object : WebChromeClient() {
        override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: android.os.Message): Boolean = false
        override fun onPermissionRequest(request: PermissionRequest) { request.deny() }
        override fun onGeolocationPermissionsShowPrompt(origin: String, callback: GeolocationPermissions.Callback) { callback.invoke(origin, false, false) }
        override fun onShowFileChooser(webView: WebView, filePathCallback: ValueCallback<Array<Uri>>, fileChooserParams: FileChooserParams): Boolean {
            filePathCallback.onReceiveValue(null)
            return true
        }
        override fun onJsAlert(view: WebView, url: String, message: String, result: JsResult): Boolean {
            pageDialog(message, result, false)
            return true
        }
        override fun onJsConfirm(view: WebView, url: String, message: String, result: JsResult): Boolean {
            pageDialog(message, result, true)
            return true
        }
        override fun onJsPrompt(view: WebView, url: String, message: String, defaultValue: String?, result: JsPromptResult): Boolean { result.cancel(); return true }
        override fun onJsBeforeUnload(view: WebView, url: String, message: String, result: JsResult): Boolean { result.cancel(); return true }
    }

    private fun pageDialog(message: String, result: JsResult, confirm: Boolean) {
        pageDialog?.dismiss()
        var completed = false
        val builder = AlertDialog.Builder(this)
            .setTitle(labels.pageMessage)
            .setMessage(message.take(2000))
            .setPositiveButton(android.R.string.ok) { _, _ -> completed = true; result.confirm() }
        if (confirm) builder.setNegativeButton(android.R.string.cancel) { _, _ -> completed = true; result.cancel() }
        pageDialog = builder.create().apply {
            setOnDismissListener { if (!completed) result.cancel() }
            show()
        }
    }

    private fun openBrowser(url: String) {
        if (BrowserIntents.launch(url) { startActivity(it) } != BrowserIntents.LaunchResult.STARTED) {
            showMessage(labels.browserFailed)
        }
    }

    private fun showMessage(message: String) = Toast.makeText(this, message, Toast.LENGTH_LONG).show()

    private fun showFailure() {
        if (::status.isInitialized) {
            status.visibility = View.VISIBLE
            status.text = labels.loadFailed
        }
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    override fun onPause() { webView?.onPause(); super.onPause() }
    override fun onResume() { super.onResume(); webView?.onResume() }
    override fun onDestroy() {
        pageDialog?.dismiss()
        releaseWebView()
        super.onDestroy()
    }

    private fun releaseWebView() {
        images?.close()
        images = null
        webView?.let {
            (it.parent as? ViewGroup)?.removeView(it)
            it.stopLoading()
            it.webChromeClient = null
            it.removeAllViews()
            it.destroy()
        }
        webView = null
    }

    companion object {
        const val EXTRA_HTML = "interactive_html.html"
        const val EXTRA_SOURCE_URL = "interactive_html.source_url"
        const val EXTRA_ACCOUNT_SCOPE = "interactive_html.account_scope"
        const val EXTRA_POST_ID = "interactive_html.post_id"
        const val EXTRA_LOCALE = "interactive_html.locale"
        const val EXTRA_LABELS = "interactive_html.labels"

        internal fun isDark(configuration: Configuration) =
            configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES

        /** Only the string values of the known label keys, from the channel call or the intent. */
        internal fun labelMap(source: Map<*, *>?): Map<String, String> = buildMap {
            source?.forEach { (key, value) -> if (key is String && key in Labels.KEYS && value is String) put(key, value) }
        }

        private fun labelMap(bundle: Bundle?): Map<String, String> =
            labelMap(bundle?.let { b -> b.keySet().associateWith { b.getString(it) } })

        fun intent(
            context: Context, html: String?, sourceUrl: String?, accountScope: String?, postId: String?,
            locale: String? = null, labels: Map<*, *>? = null,
        ): Intent {
            val texts = Bundle().apply { labelMap(labels).forEach { (key, value) -> putString(key, value) } }
            val checked = InteractiveHtmlPolicy.validate(html, sourceUrl, accountScope, postId)
            return Intent(context, InteractiveHtmlActivity::class.java)
                .putExtra(EXTRA_HTML, checked.html)
                .putExtra(EXTRA_SOURCE_URL, checked.sourceUrl)
                .putExtra(EXTRA_ACCOUNT_SCOPE, checked.accountScope)
                .putExtra(EXTRA_POST_ID, checked.postId)
                .putExtra(EXTRA_LOCALE, locale)
                .putExtra(EXTRA_LABELS, texts)
        }
    }

    /**
     * Texts of the viewer in the language chosen in the app, not the system one. The app sends them translated from
     * its own strings; the tables below only cover a call without them (e.g. an older Dart side).
     */
    data class Labels(
        val title: String, val back: String, val original: String, val originalDescription: String,
        val loading: String, val loadFailed: String, val openFailed: String, val linkFailed: String,
        val browserFailed: String, val downloadInOriginal: String, val pageMessage: String,
    ) {
        companion object {
            private val simplified = Labels(
                "互动内容", "返回", "原文", "在浏览器查看原文", "正在加载…", "互动内容无法加载，请点击「原文」查看。",
                "无法打开互动内容", "无法打开链接", "无法打开浏览器", "请从原文下载文件", "页面提示",
            )
            private val traditional = Labels(
                "互動內容", "返回", "原文", "在瀏覽器查看原文", "正在載入…", "互動內容無法載入，請點選「原文」查看。",
                "無法開啟互動內容", "無法開啟連結", "無法開啟瀏覽器", "請從原文下載檔案", "頁面提示",
            )
            private val english = Labels(
                "Interactive content", "Back", "Original", "Open original page in browser", "Loading…",
                "Unable to load interactive content. Open the original page instead.",
                "Unable to open interactive content", "Unable to open link", "Unable to open browser",
                "Open the original page to download files", "Page message",
            )

            /** Keys of the texts sent by the app, in the order of the constructor. */
            val KEYS = listOf(
                "title", "back", "original", "originalDescription", "loading", "loadFailed", "openFailed",
                "linkFailed", "browserFailed", "downloadInOriginal", "pageMessage",
            )

            /** The texts sent by the app in [values], each missing or blank one from the table of [tag]. */
            fun resolve(values: Map<String, String>, tag: String?): Labels {
                val fallback = forLocale(tag)
                fun pick(key: String, default: String) = values[key]?.takeIf { it.isNotBlank() } ?: default
                return Labels(
                    pick("title", fallback.title), pick("back", fallback.back), pick("original", fallback.original),
                    pick("originalDescription", fallback.originalDescription), pick("loading", fallback.loading),
                    pick("loadFailed", fallback.loadFailed), pick("openFailed", fallback.openFailed),
                    pick("linkFailed", fallback.linkFailed), pick("browserFailed", fallback.browserFailed),
                    pick("downloadInOriginal", fallback.downloadInOriginal), pick("pageMessage", fallback.pageMessage),
                )
            }

            /** [tag] is the app's language tag (zh-CN, zh-TW, en); without one the system language decides. */
            fun forLocale(tag: String?): Labels {
                val locale = if (tag.isNullOrBlank()) Locale.getDefault() else Locale.forLanguageTag(tag)
                if (locale.language != "zh") return english
                val traditionalScript = locale.script == "Hant" ||
                    (locale.script.isEmpty() && locale.country in setOf("TW", "HK", "MO"))
                return if (traditionalScript) traditional else simplified
            }
        }
    }
}
