package kzs.th000.tsdm_client

import android.webkit.WebResourceResponse
import okhttp3.Call
import okhttp3.CookieJar
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.Proxy
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/** No WebView cookie/header, forum session, proxy, or referrer is passed to the image host. */
class InteractiveHtmlImages(private val allowedUrls: Set<String>) : AutoCloseable {
    private val requests = AtomicInteger()
    private val received = AtomicLong()
    private val closed = AtomicBoolean()
    private val activeCalls = ConcurrentHashMap.newKeySet<Call>()
    private val client = OkHttpClient.Builder()
        .cookieJar(CookieJar.NO_COOKIES)
        .proxy(Proxy.NO_PROXY)
        .dns { hostname ->
            Dns.SYSTEM.lookup(hostname).also { addresses ->
                if (addresses.isEmpty() || addresses.any { !InteractiveHtmlPolicy.publicAddress(it) }) {
                    throw UnknownHostException("Image host is not public")
                }
            }
        }
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .callTimeout(15, TimeUnit.SECONDS)
        .build()

    fun load(raw: String): WebResourceResponse {
        if (closed.get()) return blocked()
        var url = InteractiveHtmlPolicy.safeImageUrl(raw) ?: return blocked()
        if (url.toString() !in allowedUrls || requests.incrementAndGet() > 48) return blocked()
        try {
            repeat(4) {
                val call = client.newCall(Request.Builder().url(url).header("Accept", "image/avif,image/webp,image/*").build())
                activeCalls.add(call)
                try {
                    if (closed.get()) { call.cancel(); return blocked() }
                    call.execute().use { response ->
                        if (response.code in setOf(301, 302, 303, 307, 308)) {
                            url = InteractiveHtmlPolicy.safeImageUrl(response.header("Location") ?: return blocked(), url.toString())
                                ?: return blocked()
                        } else {
                            if (!response.isSuccessful) return blocked()
                            val type = response.header("Content-Type")?.substringBefore(';')?.trim()?.lowercase()
                            if (type !in setOf("image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "image/bmp", "image/x-icon")) {
                                return blocked()
                            }
                            if (response.body.contentLength() > MAX_IMAGE_BYTES) return blocked()
                            val output = ByteArrayOutputStream()
                            val buffer = ByteArray(8192)
                            response.body.byteStream().use { input ->
                                while (true) {
                                    val count = input.read(buffer)
                                    if (count < 0) break
                                    if (output.size() + count > MAX_IMAGE_BYTES || received.addAndGet(count.toLong()) > MAX_TOTAL_BYTES) {
                                        return blocked()
                                    }
                                    output.write(buffer, 0, count)
                                }
                            }
                            return WebResourceResponse(type, null, 200, "OK", mapOf(
                                "Cache-Control" to "no-store", "X-Content-Type-Options" to "nosniff",
                            ), ByteArrayInputStream(output.toByteArray()))
                        }
                    }
                } finally {
                    activeCalls.remove(call)
                }
            }
        } catch (_: Exception) {
            // A failed external image must not stop the local interactive document.
        }
        return blocked()
    }

    override fun close() {
        closed.set(true)
        activeCalls.forEach { it.cancel() }
        client.dispatcher.cancelAll()
        client.connectionPool.evictAll()
    }

    companion object {
        private const val MAX_IMAGE_BYTES = 5 * 1024 * 1024
        private const val MAX_TOTAL_BYTES = 16 * 1024 * 1024L
        fun blocked() = WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", mapOf(
            "Cache-Control" to "no-store", "X-Content-Type-Options" to "nosniff",
        ), ByteArrayInputStream(ByteArray(0)))
    }
}
