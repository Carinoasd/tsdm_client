package kzs.th000.tsdm_client

import android.net.Uri
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.net.InetAddress
import java.security.MessageDigest
import java.util.Locale

/** The document owns a synthetic origin; a forum URL is only its relative-resource base. */
object InteractiveHtmlPolicy {
    const val MAX_HTML_BYTES = 256 * 1024
    private val forumHosts = setOf("www.tsdm39.com", "tsdm39.com")

    class Failure(val code: String, override val message: String) : Exception(message)

    data class Content(val html: String, val sourceUrl: String, val accountScope: String, val postId: String) {
        val documentUrl: String by lazy {
            val scope = listOf(accountScope, sourceUrl, postId).joinToString("") { "${it.length}:$it" }
            val digest = MessageDigest.getInstance("SHA-256").digest(scope.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
            "https://p${digest.take(32)}.${digest.drop(32)}.interactive.tsdm.invalid/document.html"
        }
        val imageUrls: Set<String> by lazy { declaredImageUrls(html, sourceUrl) }
    }

    fun validate(html: String?, sourceUrl: String?, accountScope: String?, postId: String?): Content {
        if (html.isNullOrBlank() || sourceUrl.isNullOrBlank() || accountScope.isNullOrBlank() || postId.isNullOrBlank() ||
            sourceUrl.length > 4096 || accountScope.length > 128 || postId.length > 128
        ) throw Failure("interactive_html_invalid", "The interactive content request is incomplete.")
        if (html.length > MAX_HTML_BYTES || html.toByteArray(Charsets.UTF_8).size > MAX_HTML_BYTES) {
            throw Failure("interactive_html_too_large", "The interactive content is too large to open.")
        }
        val source = sourceUrl.toHttpUrlOrNull()
        if (source == null || source.scheme != "https" || source.host !in forumHosts || source.port != 443 ||
            source.username.isNotEmpty() || source.password.isNotEmpty()
        ) throw Failure("interactive_html_invalid_source", "Interactive content must come from the forum.")
        return Content(html, source.toString(), accountScope, postId)
    }

    fun isForumUrl(url: HttpUrl): Boolean = url.host in forumHosts

    fun safeLink(raw: String): HttpUrl? {
        val url = raw.toHttpUrlOrNull() ?: return null
        if (url.username.isNotEmpty() || url.password.isNotEmpty() ||
            url.port != (if (url.isHttps) 443 else 80) || !publicHostName(url.host)
        ) return null
        return url
    }

    fun safeImageUrl(raw: String, base: String? = null): HttpUrl? {
        val url = if (base == null) raw.toHttpUrlOrNull() else base.toHttpUrlOrNull()?.resolve(raw)
        if (url == null || !url.isHttps || url.port != 443 || url.username.isNotEmpty() ||
            url.password.isNotEmpty() || !publicHostName(url.host)
        ) return null
        return url.newBuilder().fragment(null).build()
    }

    /** Literal IPs and local-use hostnames are not image/link destinations. DNS is checked again at connect time. */
    internal fun publicHostName(host: String): Boolean {
        val name = host.lowercase(Locale.ROOT).trimEnd('.')
        if (!name.contains('.') || name.contains(':') || name.all { it.isDigit() || it == '.' }) return false
        return listOf("localhost", "local", "lan", "internal", "home", "test", "invalid").none {
            name == it || name.endsWith(".$it")
        }
    }

    internal fun publicAddress(address: InetAddress): Boolean {
        if (address.isAnyLocalAddress || address.isLoopbackAddress || address.isLinkLocalAddress ||
            address.isSiteLocalAddress || address.isMulticastAddress
        ) return false
        val bytes = address.address.map { it.toInt() and 0xff }
        return when (bytes.size) {
            4 -> !(bytes[0] == 0 || bytes[0] == 10 || bytes[0] == 127 || bytes[0] >= 224 ||
                (bytes[0] == 100 && bytes[1] in 64..127) ||
                (bytes[0] == 169 && bytes[1] == 254) ||
                (bytes[0] == 172 && bytes[1] in 16..31) ||
                (bytes[0] == 192 && (bytes[1] == 168 || (bytes[1] == 0 && bytes[2] in listOf(0, 2)))) ||
                (bytes[0] == 198 && (bytes[1] in 18..19 || (bytes[1] == 51 && bytes[2] == 100))) ||
                (bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113))
            16 -> bytes[0] and 0xe0 == 0x20 &&
                !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8)
            else -> false
        }
    }

    private fun unescape(value: String): String = Regex("&#(x[0-9a-f]+|[0-9]+);?|&(amp|quot|apos|lt|gt);", RegexOption.IGNORE_CASE)
        .replace(value) { match ->
            val number = match.groupValues[1]
            if (number.isNotEmpty()) {
                val code = if (number.startsWith("x", true)) number.drop(1).toIntOrNull(16) else number.toIntOrNull()
                if (code != null && Character.isValidCodePoint(code)) String(Character.toChars(code)) else ""
            } else when (match.groupValues[2].lowercase(Locale.ROOT)) {
                "amp" -> "&"
                "quot" -> "\""
                "apos" -> "'"
                "lt" -> "<"
                "gt" -> ">"
                else -> ""
            }
        }

    /** An exact URL allowlist prevents scripts turning arbitrary draft text into outgoing image URLs. */
    internal fun declaredImageUrls(html: String, sourceUrl: String): Set<String> {
        val result = linkedSetOf<String>()
        fun add(raw: String) {
            if (result.size < 128) safeImageUrl(unescape(raw.trim()), sourceUrl)?.let { result.add(it.toString()) }
        }
        val tags = Regex("<(?:img|image|source)\\b[^>]*>", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
        val attributes = Regex("(?:src|href|xlink:href|srcset)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", RegexOption.IGNORE_CASE)
        tags.findAll(html).forEach { tag ->
            attributes.findAll(tag.value).forEach { attribute ->
                val value = attribute.groupValues.drop(1).firstOrNull { it.isNotEmpty() } ?: ""
                if (attribute.value.startsWith("srcset", true)) value.split(',').forEach { add(it.trim().substringBefore(' ')) }
                else add(value)
            }
        }
        Regex("url\\(\\s*(?:\"([^\"]*)\"|'([^']*)'|([^)'\"\\s]+))\\s*\\)", RegexOption.IGNORE_CASE)
            .findAll(html).forEach { add(it.groupValues.drop(1).firstOrNull { value -> value.isNotEmpty() } ?: "") }
        return result
    }

    fun document(content: Content): String {
        val base = content.sourceUrl.replace("&", "&amp;").replace("\"", "&quot;").replace("<", "&lt;")
        return """<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="referrer" content="no-referrer"><base href="$base"><style>html{color-scheme:light dark}body{margin:12px;overflow-wrap:anywhere}img,svg{max-width:100%}*{box-sizing:border-box}</style><script>document.addEventListener('click',function(event){var node=event.target;var link=node.closest?node.closest('a[href]'):null;if(link)link.removeAttribute('target');},true);</script></head><body>${content.html}</body></html>"""
    }

    fun headers(content: Content): Map<String, String> {
        val source = requireNotNull(content.sourceUrl.toHttpUrlOrNull())
        return mapOf(
            "Content-Security-Policy" to ("default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; " +
                "img-src https: data:; font-src data:; connect-src 'none'; frame-src 'none'; child-src 'none'; " +
                "worker-src 'none'; object-src 'none'; media-src 'none'; form-action 'none'; " +
                "base-uri https://${source.host}; " +
                "sandbox allow-scripts allow-same-origin allow-modals allow-top-navigation-by-user-activation"),
            "Referrer-Policy" to "no-referrer",
            "Cache-Control" to "no-store",
            "X-Content-Type-Options" to "nosniff",
            "Permissions-Policy" to "camera=(), microphone=(), geolocation=(), payment=(), usb=(), clipboard-read=()",
        )
    }

    /** With the trusted base element, fragment links resolve against the forum URL; keep these inside the viewer. */
    fun fragment(content: Content, raw: String): String? {
        val uri = Uri.parse(raw)
        if (uri.fragment == null) return null
        val withoutFragment = uri.buildUpon().fragment(null).build().toString()
        val source = Uri.parse(content.sourceUrl).buildUpon().fragment(null).build().toString()
        return if (withoutFragment == source || withoutFragment == content.documentUrl) uri.encodedFragment else null
    }
}
