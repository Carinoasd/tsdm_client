package kzs.th000.tsdm_client

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.FormBody
import okhttp3.Headers
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import okio.BufferedSink
import java.net.ProxySelector

object HttpClient {
    private val client by lazy {
        OkHttpClient.Builder().proxySelector(ProxySelector.getDefault()).build()
    }

    // Share connections and dispatchers, but never replay a non-idempotent transaction.
    private val singleAttemptClient by lazy {
        client.newBuilder()
            .retryOnConnectionFailure(false)
            .followRedirects(false)
            .followSslRedirects(false)
            .build()
    }

    suspend fun get(url: String, headers: HashMap<String, String>): Response {
        val request = Request.Builder()
            .url(url)
            .headers(Headers.headersOf(*headers.toList().flatMap { listOf(it.first, it.second) }.toTypedArray()))
            .get()
            .build()

        return withContext(Dispatchers.IO) {
            try {
                client.newCall(request).execute()
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
