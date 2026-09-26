package kzs.th000.tsdm_client

import java.io.IOException
import java.net.URLDecoder
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.SocketEffect
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
}
