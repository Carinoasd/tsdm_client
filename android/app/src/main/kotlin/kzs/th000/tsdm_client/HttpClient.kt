package kzs.th000.tsdm_client

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.FormBody
import okhttp3.Headers
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.BufferedSink
import java.net.ProxySelector
import java.util.concurrent.TimeUnit

object HttpClient {
    // The forum answers quickly, so its requests keep the OkHttp defaults (10s): a page under a weak network must fail
    // as fast as it always did.
    private val client by lazy { OkHttpClient.Builder().proxySelector(ProxySelector.getDefault()).build() }

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

    suspend fun get(url: String, headers: HashMap<String, String>): Response {
        val request = Request.Builder()
            .url(url)
            .headers(Headers.headersOf(*headers.toList().flatMap { listOf(it.first, it.second) }.toTypedArray()))
            .get()
            .build()

        return withContext(Dispatchers.IO) {
            try {
                pick(needsMoreTime(url, headers), false).newCall(request).execute()
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

    suspend fun postMultipart(
        url: String,
        headers: Map<String, String> = emptyMap(),
        body: Map<String, String> = emptyMap(),
    ): Response {
        val multipartBody = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .apply {
                body.forEach { (key, value) -> addFormDataPart(key, value) }
            }
            .build()

        val request = Request.Builder()
            .url(url)
            .headers(Headers.headersOf(*headers.toList().flatMap { listOf(it.first, it.second) }.toTypedArray()))
            .post(multipartBody)
            .build()

        return withContext(Dispatchers.IO) {
            try {
                client.newCall(request).execute()
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
