package kzs.th000.tsdm_client

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.FormBody
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.BufferedSink
import java.io.File
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.ProxySelector
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit

object HttpClient {
    // The forum answers quickly, so its requests keep the OkHttp defaults (10s): a page under a weak network must fail
    // as fast as it always did. Every client below is built from this one and keeps its network interceptor.
    private val client by lazy {
        OkHttpClient.Builder()
            .proxySelector(ProxySelector.getDefault())
            .addNetworkInterceptor(sessionScope)
            .build()
    }

    // The Dart side puts the forum's cookie and the app's `X-Tsdmapp-*` headers in the request as plain headers, and
    // reads the `Set-Cookie` of the answer as one of the url it asked for. OkHttp follows a redirect with every header
    // but `Authorization`: these would go on to whatever host the redirect names. They only go to the host of the url
    // asked for, and not over http when that url was https ([keepsSession]); a hop anywhere else goes without them, and
    // its `Set-Cookie` is not handed back. No host is named here: a build pointed at a test forum works the same.
    private val sessionScope = Interceptor { chain ->
        val request = chain.request()
        if (keepsSession(chain.call().request().url, request.url)) {
            return@Interceptor chain.proceed(request)
        }
        val stripped = request.newBuilder().apply {
            request.headers.names()
                .filter { it.equals("Cookie", ignoreCase = true) || it.startsWith("X-Tsdmapp-", ignoreCase = true) }
                .forEach { removeHeader(it) }
        }.build()
        chain.proceed(stripped).newBuilder().removeHeader("Set-Cookie").build()
    }

    // Whether a hop to [hop] of a call asked for [origin] may carry the session headers the caller set: the same host,
    // and not https turned into http.
    internal fun keepsSession(origin: HttpUrl, hop: HttpUrl): Boolean =
        origin.host.equals(hop.host, ignoreCase = true) && (hop.isHttps || !origin.isHttps)

    // The plugin api and the image cdn answer slowly under load (the 10s defaults timed out the pokemon heal and the
    // sprite downloads on slower devices), so the requests that go there get more time.
    private val relaxedClient by lazy {
        client.newBuilder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .build()
    }

    // Share connections and dispatchers, but never replay a non-idempotent transaction.
    private val singleAttemptClient by lazy { noReplay(client) }
    private val relaxedSingleAttemptClient by lazy { noReplay(relaxedClient) }

    private fun noReplay(base: OkHttpClient) = base.newBuilder()
        .retryOnConnectionFailure(false)
        .followRedirects(false)
        .followSslRedirects(false)
        .build()

    private fun pick(relaxed: Boolean, singleAttempt: Boolean) = when {
        relaxed && singleAttempt -> relaxedSingleAttemptClient
        relaxed -> relaxedClient
        singleAttempt -> singleAttemptClient
        else -> client
    }

    // The plugin's own pages and api answer slowly, and so does the image cdn: those requests get the wider timeouts.
    // The url matters most: the read that fetches the session formhash carries no plugin header yet, and a request made
    // without one (a formhash that could not be read) has to keep the wider timeouts too.
    private fun needsMoreTime(url: String, headers: Map<String, String>): Boolean {
        if (url.contains("id=pokemon")) return true
        val wantsImage = headers.entries.any { (key, value) ->
            key.equals("Accept", ignoreCase = true) && value.startsWith("image/")
        }
        return wantsImage || headers.keys.any { it.equals("X-Pm-Formhash", ignoreCase = true) }
    }

    // Error code of a failed request for the Dart side: "KT_HTTP_UNREACHABLE" when the host was not reached at all (no
    // network, the name not resolved, the connection refused or timed out while connecting), so the app can read a
    // saved copy of a thread page instead; "KT_HTTP_ERROR" for every other failure, a socket that fails after the
    // connect included (the forum was reached).
    fun errorCode(e: Exception): String {
        val unreachable = e is UnknownHostException ||
            e is ConnectException ||
            e is NoRouteToHostException ||
            // Android's socket says so when the connect timed out; a read timeout is "timeout" or "Read timed out".
            (e is SocketTimeoutException && e.message?.startsWith("failed to connect") == true)
        return if (unreachable) "KT_HTTP_UNREACHABLE" else "KT_HTTP_ERROR"
    }

    // A GET that writes (the forum's AJAX menus, a debate vote) is never replayed either: singleAttempt.
    suspend fun get(url: String, headers: HashMap<String, String>, singleAttempt: Boolean = false): Response {
        val request = Request.Builder()
            .url(url)
            .headers(Headers.headersOf(*headers.toList().flatMap { listOf(it.first, it.second) }.toTypedArray()))
            .get()
            .build()

        return withContext(Dispatchers.IO) {
            try {
                pick(needsMoreTime(url, headers), singleAttempt).newCall(request).execute()
            } catch (e: Exception) {
                throw e
            }
        }
    }

    suspend fun postForm(
        url: String,
        headers: HashMap<String, String>,
        body: HashMap<String, String>,
        singleAttempt: Boolean = false,
    ): Response {
        val formBody = FormBody.Builder().apply {
            body.forEach { (key, value) -> add(key, value) }
        }.build()

        // retryOnConnectionFailure(false) alone does not prevent retries on all
        // responses (for example 503 + Retry-After: 0). OkHttp checks isOneShot
        // before following any response that would resend this body.
        val requestBody = if (singleAttempt) object : RequestBody() {
            override fun contentType() = formBody.contentType()
            override fun contentLength() = formBody.contentLength()
            override fun isOneShot() = true
            override fun writeTo(sink: BufferedSink) = formBody.writeTo(sink)
        } else formBody

        val request = Request.Builder()
            .url(url)
            .headers(Headers.headersOf(*headers.toList().flatMap { listOf(it.first, it.second) }.toTypedArray()))
            .post(requestBody)
            .build()

        return withContext(Dispatchers.IO) {
            try {
                (if (singleAttempt) singleAttemptClient else client).newCall(request).execute()
            } catch (e: Exception) {
                throw e
            }
        }
    }

    /**
     * A value of [body] is a string part, or a map `{"path", "filename", "contentType"}` naming a file to send as the
     * part (the file of a shared image uploaded as an attachment); any other value is sent as its string form.
     *
     * [singleAttempt] as in [postForm]: an upload the server may already have taken is never sent twice.
     */
    suspend fun postMultipart(
        url: String,
        headers: Map<String, String> = emptyMap(),
        body: Map<String, Any?> = emptyMap(),
        singleAttempt: Boolean = false,
    ): Response {
        val multipartBody = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .apply {
                body.forEach { (key, value) ->
                    when (value) {
                        is Map<*, *> -> {
                            val path = value["path"] as? String ?: throw IllegalArgumentException("file part without path")
                            val file = File(path)
                            val filename = value["filename"] as? String ?: file.name
                            val type = (value["contentType"] as? String)?.toMediaTypeOrNull()
                            addFormDataPart(key, filename, file.asRequestBody(type))
                        }
                        null -> addFormDataPart(key, "")
                        else -> addFormDataPart(key, value.toString())
                    }
                }
            }
            .build()
        val requestBody = if (singleAttempt) object : RequestBody() {
            override fun contentType() = multipartBody.contentType()
            override fun contentLength() = multipartBody.contentLength()
            override fun isOneShot() = true
            override fun writeTo(sink: BufferedSink) = multipartBody.writeTo(sink)
        } else multipartBody

        val request = Request.Builder()
            .url(url)
            .headers(Headers.headersOf(*headers.toList().flatMap { listOf(it.first, it.second) }.toTypedArray()))
            .post(requestBody)
            .build()

        return withContext(Dispatchers.IO) {
            try {
                (if (singleAttempt) singleAttemptClient else client).newCall(request).execute()
            } catch (e: Exception) {
                throw e
            }
        }
    }

    suspend fun postJson(
        url: String,
        headers: HashMap<String, String>,
        body: String,
        singleAttempt: Boolean = false,
    ): Response {
        val jsonBody = body.toRequestBody("application/json; charset=utf-8".toMediaType())

        // Same reason as postForm: a write the server may already have carried out must not be sent a second time, so a
        // one-shot body (OkHttp checks isOneShot before resending) goes out on the client that does not retry.
        val requestBody = if (singleAttempt) object : RequestBody() {
            override fun contentType() = jsonBody.contentType()
            override fun contentLength() = jsonBody.contentLength()
            override fun isOneShot() = true
            override fun writeTo(sink: BufferedSink) = jsonBody.writeTo(sink)
        } else jsonBody

        val request = Request.Builder()
            .url(url)
            .headers(Headers.headersOf(*headers.toList().flatMap { listOf(it.first, it.second) }.toTypedArray()))
            .post(requestBody)
            .build()

        return withContext(Dispatchers.IO) {
            try {
                pick(needsMoreTime(url, headers), singleAttempt).newCall(request).execute()
            } catch (e: Exception) {
                throw e
            }
        }
    }
}

fun buildResponse(
    statusCode: Int,
    headers: HashMap<String, List<String>>,
    body: ByteArray,
    isRedirect: Boolean,
) : HashMap<String, Any>{
    return hashMapOf(
        Pair("statusCode", statusCode),
        Pair("headers", headers),
        Pair("body", body),
        Pair("isRedirect", isRedirect),
    )
}
