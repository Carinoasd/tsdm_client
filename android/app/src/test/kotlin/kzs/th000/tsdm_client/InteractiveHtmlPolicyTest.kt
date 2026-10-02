package kzs.th000.tsdm_client

import android.net.Uri
import java.net.InetAddress
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE)
class InteractiveHtmlPolicyTest {
    private val source = "https://www.tsdm39.com/forum.php?mod=viewthread&tid=1266801"
    private fun content(html: String = "<button onclick=\"this.textContent='ok'\">Run</button>", account: String = "123", post: String = "42") =
        InteractiveHtmlPolicy.validate(html, source, account, post)

    @Test fun onlyVerifiedHttpsForumSourcesAreAccepted() {
        for (url in listOf("http://www.tsdm39.com/forum.php", "https://www.tsdm39.com.evil.example/forum.php",
            "https://evil.example/", "https://user:secret@www.tsdm39.com/forum.php", "https://www.tsdm39.com:444/forum.php",
            "javascript:alert(1)", "file:///tmp/forum.php", "https://localhost/")) {
            assertThrows(InteractiveHtmlPolicy.Failure::class.java) { InteractiveHtmlPolicy.validate("<p>x</p>", url, "guest", "42") }
        }
        assertEquals("https://tsdm39.com/", InteractiveHtmlPolicy.validate("x", "https://tsdm39.com/", "guest", "42").sourceUrl)
    }

    @Test fun payloadLimitCountsUtf8BytesNotOnlyCharacters() {
        val failure = assertThrows(InteractiveHtmlPolicy.Failure::class.java) { content("天".repeat(100_000)) }
        assertEquals("interactive_html_too_large", failure.code)
        assertThrows(InteractiveHtmlPolicy.Failure::class.java) { content("a".repeat(InteractiveHtmlPolicy.MAX_HTML_BYTES + 1)) }
        assertThrows(InteractiveHtmlPolicy.Failure::class.java) { content(account = " ") }
    }

    @Test fun storageOriginsAreStableAndSeparateAccountsPostsAndSourcePages() {
        val original = content()
        assertEquals(original.documentUrl, content().documentUrl)
        assertNotEquals(original.documentUrl, content(account = "guest").documentUrl)
        assertNotEquals(original.documentUrl, content(post = "43").documentUrl)
        assertNotEquals(original.documentUrl, InteractiveHtmlPolicy.validate("x", "$source&page=2", "123", "42").documentUrl)
        val uri = Uri.parse(original.documentUrl)
        assertEquals("https", uri.scheme)
        assertTrue(uri.host!!.endsWith(".interactive.tsdm.invalid"))
        assertTrue(uri.host!!.split('.').all { it.length <= 63 })
        assertFalse(original.documentUrl.contains("1266801"))
    }

    @Test fun originalInlineHtmlAndDomHandlersArePreservedUnderNetworkRestrictiveCsp() {
        val html = "<style>.card{color:red}</style><svg><path d='M1 1L2 2'/></svg><button onclick=\"localStorage.setItem('draft','hi');window.confirm('ok')\">Save</button>"
        val page = content(html)
        val document = InteractiveHtmlPolicy.document(page)
        assertTrue(document.contains(html))
        assertTrue(document.contains("<base href=\"https://www.tsdm39.com/forum.php?mod=viewthread&amp;tid=1266801\">"))
        val csp = InteractiveHtmlPolicy.headers(page).getValue("Content-Security-Policy")
        for (directive in listOf("script-src 'unsafe-inline'", "style-src 'unsafe-inline'", "connect-src 'none'",
            "frame-src 'none'", "worker-src 'none'", "form-action 'none'", "object-src 'none'", "default-src 'none'")) assertTrue(csp.contains(directive))
        assertFalse(csp.contains("unsafe-eval"))
        assertFalse(csp.contains("allow-popups"))
        assertEquals("no-referrer", InteractiveHtmlPolicy.headers(page)["Referrer-Policy"])
    }

    @Test fun declaredImagesResolveRelativeUrlsAndDoNotGrantDynamicImageRequests() {
        val page = content("""<img src="/data/a.png?x=1&amp;y=2"><source srcset="https://cdn.example.com/a.webp 1x, https://cdn.example.com/b.webp 2x"><svg><image xlink:href="https://cdn.example.com/c.png"/></svg><div style="background:url('/data/bg.png')"></div>""")
        assertEquals(setOf("https://www.tsdm39.com/data/a.png?x=1&y=2", "https://cdn.example.com/a.webp",
            "https://cdn.example.com/b.webp", "https://cdn.example.com/c.png", "https://www.tsdm39.com/data/bg.png"), page.imageUrls)
        InteractiveHtmlImages(page.imageUrls).use { loader ->
            assertEquals(403, loader.load("https://cdn.example.com/a.webp?draft=private").statusCode)
            assertEquals(403, loader.load("https://other.example.com/a.webp").statusCode)
            loader.close()
            assertEquals(403, loader.load("https://cdn.example.com/a.webp").statusCode)
        }
    }

    @Test fun localAndNonHttpsImagesAreNeverEligible() {
        for (url in listOf("http://cdn.example.com/a.png", "file:///etc/passwd", "content://contacts/1", "https://localhost/a",
            "https://a.local/a", "https://192.168.1.2/a", "https://127.0.0.1/a", "https://[::1]/a",
            "https://user:pass@cdn.example.com/a.png", "https://cdn.example.com:8443/a.png")) {
            assertNull(url, InteractiveHtmlPolicy.safeImageUrl(url))
        }
        assertNotNull(InteractiveHtmlPolicy.safeImageUrl("https://cdn.example.com/a.png"))
    }

    @Test fun dnsPolicyRejectsPrivateAndSpecialUseAddressesIncludingIpv6() {
        for (ip in listOf("0.0.0.0", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.169.254", "172.31.1.1",
            "192.168.1.1", "192.0.2.1", "198.18.0.1", "224.0.0.1", "::1", "fe80::1", "fd12::1", "2001:db8::1")) {
            assertFalse(ip, InteractiveHtmlPolicy.publicAddress(InetAddress.getByName(ip)))
        }
        for (ip in listOf("8.8.8.8", "1.1.1.1", "2606:4700:4700::1111")) {
            assertTrue(ip, InteractiveHtmlPolicy.publicAddress(InetAddress.getByName(ip)))
        }
    }

    @Test fun anchorsStayLocalOnlyForTheSourceAndSyntheticDocument() {
        val page = content()
        assertEquals("section", InteractiveHtmlPolicy.fragment(page, "$source#section"))
        assertEquals("section", InteractiveHtmlPolicy.fragment(page, "${page.documentUrl}#section"))
        assertNull(InteractiveHtmlPolicy.fragment(page, "https://evil.example/#section"))
        assertNull(InteractiveHtmlPolicy.fragment(page, source))
    }
}
