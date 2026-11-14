package kzs.th000.tsdm_client

import java.io.IOException
import java.net.URLDecoder
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.SocketEffect
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test

/** Exercises the actual app transport; a mocked Dart callback cannot detect OkHttp replays. */
class HttpClientTest {
    private val form = hashMapOf(
        "bankid" to "1",
        "action" to "cur",
        "banknum" to "12",
        "op" to "in",
        "bankpass" to "synthetic secret + & 測試",
    )

    @Test fun singleAttemptPreservesFormEncoding() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse(body = "Response is not a confirmation"))
            server.start()
            HttpClient.postForm(server.url("/bank").toString(), hashMapOf(), form, singleAttempt = true).use {
                assertEquals(200, it.code)
            }
            val request = requireNotNull(server.takeRequest(1, TimeUnit.SECONDS))
            assertEquals("POST", request.method)
            assertEquals("application/x-www-form-urlencoded", request.headers["Content-Type"])
            val decoded = requireNotNull(request.body).utf8().split('&').associate { part ->
                val (key, value) = part.split('=', limit = 2)
                URLDecoder.decode(key, "UTF-8") to URLDecoder.decode(value, "UTF-8")
            }
            assertEquals(form, decoded)
            assertEquals(1, server.requestCount)
        }
    }

    @Test fun singleAttemptDoesNotReplay408() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse(code = 408))
            server.enqueue(MockResponse(body = "Would be a second transaction"))
            server.start()
            HttpClient.postForm(server.url("/bank").toString(), hashMapOf(), form, singleAttempt = true).use {
                assertEquals(408, it.code)
            }
            assertEquals(1, server.requestCount)
        }
    }

    @Test fun singleAttemptDoesNotReplay503EvenWhenTheServerRequestsImmediateRetry() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse.Builder().code(503).addHeader("Retry-After", "0").build())
            server.enqueue(MockResponse(body = "Would be a second transaction"))
            server.start()
            HttpClient.postForm(server.url("/bank").toString(), hashMapOf(), form, singleAttempt = true).use {
                assertEquals(503, it.code)
            }
            assertEquals(1, server.requestCount)
        }
    }

    @Test fun singleAttemptDoesNotFollowAnyRedirectIncludingBodyPreservingRedirects() = runBlocking {
        for (status in listOf(301, 302, 303, 307, 308)) {
            MockWebServer().use { server ->
                server.enqueue(MockResponse.Builder().code(status).addHeader("Location", "/replay").build())
                server.enqueue(MockResponse(body = "Must not be requested"))
                server.start()
                HttpClient.postForm(server.url("/bank").toString(), hashMapOf(), form, singleAttempt = true).use {
                    assertEquals(status, it.code)
                }
                assertEquals("Redirect $status must not cause another request", 1, server.requestCount)
                assertEquals("/bank", server.takeRequest(1, TimeUnit.SECONDS)?.target)
            }
        }
    }

    @Test fun unreachableHostsAreToldApartFromOtherFailures() = runBlocking {
        fun codeOf(block: suspend () -> Unit): String {
            val error = runCatching { runBlocking { block() } }.exceptionOrNull()
            assertNotNull("the request must fail", error)
            return HttpClient.errorCode(error as Exception)
        }

        // Nothing listens on the port any more: the connection is refused.
        val port = MockWebServer().use { server ->
            server.start()
            server.port
        }
        assertEquals("KT_HTTP_UNREACHABLE", codeOf { HttpClient.get("http://localhost:$port/forum.php", hashMapOf()).close() })
        // A name that never resolves (`.invalid` is reserved for that).
        assertEquals("KT_HTTP_UNREACHABLE", codeOf { HttpClient.get("http://forum.invalid/forum.php", hashMapOf()).close() })

        // Connected, then the socket closed before the answer: the forum was reached.
        MockWebServer().use { server ->
            repeat(3) { server.enqueue(MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build()) }
            server.start()
            assertEquals("KT_HTTP_ERROR", codeOf { HttpClient.get(server.url("/forum.php").toString(), hashMapOf()).close() })
        }

        assertEquals("KT_HTTP_UNREACHABLE", HttpClient.errorCode(java.net.SocketTimeoutException("failed to connect to /x (port 443) after 10000ms")))
        assertEquals("KT_HTTP_ERROR", HttpClient.errorCode(java.net.SocketTimeoutException("timeout")))
        assertEquals("KT_HTTP_ERROR", HttpClient.errorCode(java.net.SocketException("Connection reset")))
        assertEquals("KT_HTTP_ERROR", HttpClient.errorCode(javax.net.ssl.SSLHandshakeException("bad certificate")))
    }

    @Test fun losingTheResponseAfterReceivingTheFormDoesNotResendIt() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build())
            server.enqueue(MockResponse(body = "Would be a second transaction"))
            server.start()
            try {
                HttpClient.postForm(server.url("/bank").toString(), hashMapOf(), form, singleAttempt = true).close()
                fail("The lost response must be reported to the caller for GET-only reconciliation")
            } catch (_: IOException) {
                // The server has the POST body, but the caller cannot know whether it was accepted.
            }
            val request = requireNotNull(server.takeRequest(1, TimeUnit.SECONDS))
            assertEquals("POST", request.method)
            assertTrue(requireNotNull(request.body).utf8().contains("banknum=12"))
            assertEquals(1, server.requestCount)
        }
    }

    @Test fun singleAttemptGetIsNotReplayedNorRedirected() = runBlocking {
        // A GET that writes (a debate vote) is sent once: a lost response is reported, a redirect is not followed.
        MockWebServer().use { server ->
            server.enqueue(MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build())
            server.enqueue(MockResponse(body = "Would be a second vote"))
            server.start()
            try {
                HttpClient.get(server.url("/vote?stand=1").toString(), hashMapOf(), singleAttempt = true).close()
                fail("The lost response must be reported to the caller")
            } catch (_: IOException) {
                // The forum may have counted the vote: only reading the page tells.
            }
            assertEquals(1, server.requestCount)
        }
        MockWebServer().use { server ->
            server.enqueue(MockResponse.Builder().code(302).addHeader("Location", "/replay").build())
            server.enqueue(MockResponse(body = "Must not be requested"))
            server.start()
            HttpClient.get(server.url("/vote?stand=1").toString(), hashMapOf(), singleAttempt = true).use {
                assertEquals(302, it.code)
            }
            assertEquals(1, server.requestCount)
        }
    }

    @Test fun ordinaryFormsKeepTheirExisting503RetryBehavior() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse.Builder().code(503).addHeader("Retry-After", "0").build())
            server.enqueue(MockResponse(body = "Retried ordinary form"))
            server.start()
            HttpClient.postForm(server.url("/ordinary").toString(), hashMapOf(), hashMapOf("field" to "value")).use {
                assertEquals(200, it.code)
            }
            assertEquals(2, server.requestCount)
        }
    }

    @Test fun ordinaryFormsKeepTheirExistingRedirectBehavior() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse.Builder().code(303).addHeader("Location", "/result").build())
            server.enqueue(MockResponse(body = "Ordinary form result"))
            server.start()
            HttpClient.postForm(server.url("/ordinary").toString(), hashMapOf(), hashMapOf("field" to "value")).use {
                assertEquals(200, it.code)
            }
            assertEquals("POST", server.takeRequest(1, TimeUnit.SECONDS)?.method)
            val result = requireNotNull(server.takeRequest(1, TimeUnit.SECONDS))
            assertEquals("GET", result.method)
            assertEquals("/result", result.target)
            assertEquals(2, server.requestCount)
        }
    }

    private val sessionHeaders = hashMapOf(
        "Cookie" to "s_auth=synthetic",
        "X-Tsdmapp-Device" to "synthetic-device",
        "X-Tsdmapp-Other" to "synthetic",
        "Accept" to "text/html",
    )

    @Test fun aRedirectOnTheSameHostKeepsTheSessionHeaders() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse.Builder().code(302).addHeader("Location", "/next").build())
            server.enqueue(MockResponse.Builder().addHeader("Set-Cookie", "s_last=1").body("page").build())
            server.start()
            HttpClient.get("http://localhost:${server.port}/forum.php", sessionHeaders).use {
                assertEquals(200, it.code)
                assertEquals("s_last=1", it.headers["Set-Cookie"])
            }
            server.takeRequest(1, TimeUnit.SECONDS)
            val next = requireNotNull(server.takeRequest(1, TimeUnit.SECONDS))
            assertEquals("/next", next.target)
            assertEquals("s_auth=synthetic", next.headers["Cookie"])
            assertEquals("synthetic-device", next.headers["X-Tsdmapp-Device"])
        }
    }

    @Test fun aRedirectToAnotherHostDropsTheSessionHeadersAndItsCookies() = runBlocking {
        MockWebServer().use { other ->
            other.enqueue(MockResponse.Builder().addHeader("Set-Cookie", "s_auth=foreign").body("file").build())
            other.start()
            MockWebServer().use { forum ->
                // Another host name for the same machine: `localhost` asked for, `127.0.0.1` redirected to.
                forum.enqueue(
                    MockResponse.Builder().code(302).addHeader("Location", "http://127.0.0.1:${other.port}/file").build(),
                )
                forum.start()
                HttpClient.get("http://localhost:${forum.port}/forum.php?mod=attachment", sessionHeaders).use {
                    assertEquals(200, it.code)
                    assertEquals("127.0.0.1", it.request.url.host)
                    assertNull("a cookie of another host is not handed back", it.headers["Set-Cookie"])
                }
                val first = requireNotNull(forum.takeRequest(1, TimeUnit.SECONDS))
                assertEquals("s_auth=synthetic", first.headers["Cookie"])
            }
            val hop = requireNotNull(other.takeRequest(1, TimeUnit.SECONDS))
            assertNull(hop.headers["Cookie"])
            assertTrue(hop.headers.names().none { it.startsWith("X-Tsdmapp-", ignoreCase = true) })
            assertEquals("text/html", hop.headers["Accept"])
        }
    }

    @Test fun theSessionStaysOnTheHostAndNeverLeavesHttpsForHttp() {
        fun keeps(origin: String, hop: String) =
            HttpClient.keepsSession(origin.toHttpUrl(), hop.toHttpUrl())

        assertTrue(keeps("https://www.forum.test/forum.php", "https://www.forum.test/next"))
        assertTrue(keeps("http://127.0.0.1/forum.php", "http://127.0.0.1/next"))
        assertTrue(keeps("http://www.forum.test/forum.php", "https://www.forum.test/forum.php"))
        assertFalse(keeps("https://www.forum.test/forum.php", "http://www.forum.test/forum.php"))
        assertFalse(keeps("https://www.forum.test/forum.php", "https://forum.test/forum.php"))
        assertFalse(keeps("https://www.forum.test/forum.php", "https://www.forum.test.example/forum.php"))
        assertFalse(keeps("https://www.forum.test/forum.php", "https://cdn.example/file"))
    }
}
