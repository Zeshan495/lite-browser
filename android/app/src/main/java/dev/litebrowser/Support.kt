package dev.litebrowser

import android.content.Context
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL
import java.net.URLEncoder

// ---------------------------------------------------------------------------------------------
// Address bar rules (same as the Mac app)
// ---------------------------------------------------------------------------------------------

object Web {
    const val HOME = "file:///android_asset/home.html"

    fun googleSearch(q: String) = "https://www.google.com/search?q=" + URLEncoder.encode(q, "UTF-8")

    /** URLs and domains are opened; anything else is searched on Google. */
    fun resolveInput(raw: String): String {
        val t = raw.trim()
        if (t.isEmpty()) return HOME
        if (Regex("^(https?|file)://", RegexOption.IGNORE_CASE).containsMatchIn(t)) return t
        val looksLikeHost = !t.contains(' ') &&
            (Regex("\\.[a-zA-Z]{2,}(/|:|$)").containsMatchIn(t) || t.startsWith("localhost"))
        if (looksLikeHost) {
            val local = t.startsWith("localhost") || t.startsWith("127.") || t.startsWith("192.168.")
            return (if (local) "http://" else "https://") + t
        }
        return googleSearch(t)
    }

    fun isHome(url: String?) = url == HOME

    fun googleQuery(url: String?): String? {
        if (url == null) return null
        val u = Uri.parse(url)
        val host = u.host ?: return null
        if (!host.contains("google.") || u.path != "/search") return null
        return u.getQueryParameter("q")?.takeIf { it.isNotBlank() }
    }

    /** What the address bar shows when you're not typing: "github.com/apple" or the search words. */
    fun pretty(url: String?): String {
        if (url == null || isHome(url) || url.startsWith("about:") || url.startsWith("data:")) return ""
        googleQuery(url)?.let { return it }
        val u = Uri.parse(url)
        val host = u.host?.removePrefix("www.") ?: return url
        val path = if (u.path == "/" || u.path == null) "" else u.path!!
        return host + path
    }

    fun esc(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        .replace("\"", "&quot;").replace("'", "&#39;")
}

// ---------------------------------------------------------------------------------------------
// History, searches and top sites (stored on the phone only)
// ---------------------------------------------------------------------------------------------

class HistoryStore(context: Context) {
    data class Item(val url: String, val title: String, val time: Long)
    data class Search(val query: String, val time: Long)

    private val prefs = context.getSharedPreferences("litebrowser", Context.MODE_PRIVATE)
    val items = mutableListOf<Item>()
    val searches = mutableListOf<Search>()

    init {
        runCatching {
            val a = JSONArray(prefs.getString("history", "[]"))
            for (i in 0 until a.length()) a.getJSONObject(i).let { items += Item(it.getString("u"), it.optString("t"), it.getLong("d")) }
            val s = JSONArray(prefs.getString("searches", "[]"))
            for (i in 0 until s.length()) s.getJSONObject(i).let { searches += Search(it.getString("q"), it.getLong("d")) }
        }
    }

    var hidden: Set<String>
        get() = prefs.getStringSet("hiddenTopSites", emptySet())!!.toSet()
        set(v) { prefs.edit().putStringSet("hiddenTopSites", HashSet(v)).apply() }

    fun record(url: String, title: String) {
        val now = System.currentTimeMillis()
        if (items.firstOrNull()?.url == url) items[0] = Item(url, title, now)
        else { items.add(0, Item(url, title, now)); if (items.size > 3000) items.subList(3000, items.size).clear() }
        Web.googleQuery(url)?.let { q ->
            if (searches.firstOrNull()?.query != q) {
                searches.add(0, Search(q, now))
                if (searches.size > 1000) searches.subList(1000, searches.size).clear()
            }
        }
        save()
    }

    fun clearHistory() { items.clear(); save() }

    /** Also removes Google result pages from history, since their addresses contain the search. */
    fun clearSearches() {
        searches.clear()
        items.removeAll { Web.googleQuery(it.url) != null }
        save()
    }

    /** Latest distinct pages (no Google result pages), for the home page's "Recently visited". */
    fun recent(limit: Int = 5): JSONArray {
        val out = JSONArray()
        val seen = HashSet<String>()
        for (it in items) {
            if (out.length() >= limit) break
            val u = Uri.parse(it.url)
            val host = u.host ?: continue
            if (u.scheme != "http" && u.scheme != "https") continue
            if (Web.googleQuery(it.url) != null || !seen.add(it.url)) continue
            out.put(JSONObject().put("title", it.title).put("url", it.url).put("host", host).put("time", it.time))
        }
        return out
    }

    /** Most-visited sites, with recent visits counting more (same formula as the Mac app). */
    fun topSites(limit: Int = 8): JSONArray {
        val hiddenNow = hidden
        val now = System.currentTimeMillis()
        val score = HashMap<String, Double>()
        val info = HashMap<String, Pair<String, String>>()
        for (it in items.take(4000)) {
            val u = Uri.parse(it.url)
            val scheme = u.scheme ?: continue
            if (scheme != "http" && scheme != "https") continue
            val raw = u.host?.lowercase() ?: continue
            val host = raw.removePrefix("www.").removePrefix("m.").removePrefix("mobile.")
            if (host in hiddenNow || host == "accounts.google.com") continue
            val ageDays = (now - it.time) / 86_400_000.0
            score[host] = (score[host] ?: 0.0) + 1.0 / (1.0 + ageDays / 7.0)
            if (host !in info) info[host] = "$scheme://$host/" to it.title
        }
        val out = JSONArray()
        score.entries.sortedByDescending { it.value }.take(limit).forEach { e ->
            val (url, title) = info[e.key]!!
            out.put(JSONObject().put("host", e.key).put("url", url).put("title", title))
        }
        return out
    }

    private fun save() {
        val a = JSONArray()
        items.forEach { a.put(JSONObject().put("u", it.url).put("t", it.title).put("d", it.time)) }
        val s = JSONArray()
        searches.forEach { s.put(JSONObject().put("q", it.query).put("d", it.time)) }
        prefs.edit().putString("history", a.toString()).putString("searches", s.toString()).apply()
    }
}

// ---------------------------------------------------------------------------------------------
// DNS and connection checks (run these on a background thread)
// ---------------------------------------------------------------------------------------------

object Net {
    private val endpoints = listOf("https://1.1.1.1/dns-query", "https://8.8.8.8/resolve")

    /** Asks public DNS by IP address, so it works even when the phone's DNS is broken. */
    private fun dohAnswers(host: String): Pair<Boolean, List<String>>? {
        for (base in endpoints) {
            try {
                val url = URL("$base?name=" + URLEncoder.encode(host, "UTF-8") + "&type=A")
                val c = url.openConnection() as HttpURLConnection
                c.connectTimeout = 4000
                c.readTimeout = 4000
                c.setRequestProperty("Accept", "application/dns-json")
                val body = c.inputStream.bufferedReader().use { it.readText() }
                val json = JSONObject(body)
                val ips = mutableListOf<String>()
                json.optJSONArray("Answer")?.let { arr ->
                    for (i in 0 until arr.length()) {
                        val a = arr.getJSONObject(i)
                        if (a.optInt("type") == 1) ips += a.optString("data")
                    }
                }
                return (json.optInt("Status", -1) == 0 && ips.isNotEmpty()) to ips
            } catch (_: Exception) {
            }
        }
        return null
    }

    /** "resolved", "nx" (site doesn't exist) or "unreachable" (no internet). */
    fun publicLookup(host: String): String {
        val r = dohAnswers(host) ?: return "unreachable"
        return if (r.first) "resolved" else "nx"
    }

    fun systemResolve(host: String): List<String> =
        try { InetAddress.getAllByName(host).mapNotNull { it.hostAddress } } catch (_: Exception) { emptyList() }

    fun isBlockAddress(ip: String): Boolean {
        if (ip == "0.0.0.0" || ip == "::" || ip == "::1" || ip.startsWith("127.") || ip.startsWith("10.") ||
            ip.startsWith("192.168.") || ip.startsWith("169.254.") || ip.lowercase().startsWith("fe80")) return true
        if (ip.startsWith("172.")) ip.split(".").getOrNull(1)?.toIntOrNull()?.let { if (it in 16..31) return true }
        return false
    }

    fun canConnect(ip: String): Boolean =
        try { Socket().use { it.connect(InetSocketAddress(ip, 443), 4000) }; true } catch (_: Exception) { false }

    /** "blocked:<answers>", "wrong", "unreachable" or "slow". */
    fun diagnose(host: String): String {
        val mine = systemResolve(host)
        if (mine.isNotEmpty() && mine.all { isBlockAddress(it) }) return "blocked:" + mine.joinToString(", ")
        if (mine.take(2).any { canConnect(it) }) return "slow"
        val pub = dohAnswers(host)?.second ?: emptyList()
        if (pub.take(2).any { canConnect(it) }) return "wrong"
        return "unreachable"
    }
}

// ---------------------------------------------------------------------------------------------
// Friendly error pages (replace Chrome-style DNS_PROBE / ERR_NAME_NOT_RESOLVED screens)
// ---------------------------------------------------------------------------------------------

object ErrorPage {
    fun html(kind: String, host: String, detail: String, token: String): String {
        val h = Web.esc(host)
        var title: String
        var body: String
        var note = ""
        var buttons = listOf("Try again" to "retry")
        when (kind) {
            "checking" -> {
                title = "Checking why $host won't load…"
                body = "LiteBrowser is testing your DNS and your connection to <b>$h</b>."
                buttons = emptyList()
            }
            "dns" -> {
                title = "Your DNS couldn't find this site"
                body = "<b>$h</b> is online (LiteBrowser checked through secure public DNS), but the DNS server your phone uses didn't answer. It's failing or blocking this site."
                note = "Fix: Settings → Network &amp; internet → Private DNS → enter <b>dns.google</b> or <b>one.one.one.one</b> (or your own, e.g. love.dns.zeshanhaider.dev)."
                buttons = listOf("Open Private DNS settings" to "privatedns", "Try again" to "retry")
            }
            "nosite" -> {
                title = "That site doesn't exist"
                body = "Public DNS has no record of <b>$h</b>. Check the spelling, or search for it."
                buttons = listOf("Search Google" to "search", "Try again" to "retry")
            }
            "offline" -> {
                title = "You're offline"
                body = "LiteBrowser can't reach the internet. Check Wi-Fi or mobile data."
                note = "This page reloads by itself when you're back online."
            }
            "blocked" -> {
                title = "$host is blocked by your DNS"
                body = "Your DNS answered with <code>${Web.esc(detail)}</code> instead of the site's real address, so it can never load. DNS filters often block crypto, ads, gambling or adult sites."
                note = "If you run this DNS server, allow $h in its blocklist. Otherwise change Private DNS to dns.google."
                buttons = listOf("Open Private DNS settings" to "privatedns", "Try again" to "retry")
            }
            "wrong" -> {
                title = "Your DNS is sending $host to the wrong place"
                body = "The address your DNS gives for <b>$h</b> doesn't respond, but the address from public DNS works. Your DNS or provider is redirecting or blocking it."
                buttons = listOf("Open Private DNS settings" to "privatedns", "Try again" to "retry")
            }
            "unreachable" -> {
                title = "Your network can't reach $host"
                body = "DNS is fine, but LiteBrowser couldn't connect to <b>$h</b> at any of its addresses. The site is down, or your network or provider blocks it."
                note = "Try another network, such as mobile data instead of Wi-Fi."
                buttons = listOf("Try again" to "retry", "Is it down for everyone?" to "isdown")
            }
            "slow" -> {
                title = "$host is responding slowly"
                body = "Your DNS and connection are fine, but the site didn't answer in time. Try again in a moment."
            }
            else -> {
                title = "This page couldn't load"
                body = Web.esc(detail)
            }
        }
        val btnHtml = buttons.mapIndexed { i, (label, action) ->
            "<button class=\"${if (i == 0) "primary" else ""}\" onclick=\"send('$action')\">${Web.esc(label)}</button>"
        }.joinToString("")
        return """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
            <title>${Web.esc(title)}</title><style>
            :root{color-scheme:light dark}
            body{font:16px -apple-system,system-ui,Roboto,sans-serif;margin:0;padding:12vh 24px;line-height:1.55}
            h1{font-size:23px;margin:0 0 12px} p{opacity:.85} code{font-size:14px}
            button{font:inherit;padding:10px 18px;margin:10px 8px 0 0;border-radius:10px;border:1px solid #8886;background:transparent;color:inherit}
            button.primary{background:#2563eb;border-color:#2563eb;color:#fff}
            .note{font-size:14px;opacity:.65;margin-top:22px}
            </style></head><body>
            <h1>${Web.esc(title)}</h1><p>$body</p><div>$btnHtml</div>
            ${if (note.isEmpty()) "" else "<p class=\"note\">$note</p>"}
            <script>function send(a){ LiteAndroid.post(JSON.stringify({action:a, token:'$token'})) }</script>
            </body></html>
        """.trimIndent()
    }
}

// ---------------------------------------------------------------------------------------------
// PIN lock: 2 wrong PINs in a row erase all browsing data (see MainActivity.factoryReset)
// ---------------------------------------------------------------------------------------------

object AppLock {
    const val MAX_FAILURES = 2
    private fun prefs(c: Context) = c.getSharedPreferences("litebrowser_lock", Context.MODE_PRIVATE)

    fun isEnabled(c: Context) = prefs(c).getString("hash", null) != null
    fun isValidFormat(pin: String) = pin.length in 4..10 && pin.all { it in '0'..'9' }

    /** Wrong attempts in a row, written to disk immediately so closing the app doesn't reset it. */
    fun failures(c: Context) = prefs(c).getInt("failures", 0)
    fun setFailures(c: Context, n: Int) { prefs(c).edit().putInt("failures", n).commit() }

    fun set(c: Context, pin: String) {
        val salt = ByteArray(16).also { java.security.SecureRandom().nextBytes(it) }
        val saltB64 = android.util.Base64.encodeToString(salt, android.util.Base64.NO_WRAP)
        prefs(c).edit().putString("salt", saltB64).putString("hash", hash(pin, salt)).putInt("failures", 0).commit()
    }

    fun disable(c: Context) { prefs(c).edit().clear().commit() }

    fun verify(c: Context, pin: String): Boolean {
        val p = prefs(c)
        val stored = p.getString("hash", null) ?: return false
        val salt = android.util.Base64.decode(p.getString("salt", "") ?: "", android.util.Base64.NO_WRAP)
        return java.security.MessageDigest.isEqual(hash(pin, salt).toByteArray(), stored.toByteArray())
    }

    /** PBKDF2, 60,000 rounds: slow to brute-force even if someone copies the app's files. */
    private fun hash(pin: String, salt: ByteArray): String {
        val spec = javax.crypto.spec.PBEKeySpec(pin.toCharArray(), salt, 60_000, 256)
        val key = javax.crypto.SecretKeyFactory.getInstance("PBKDF2WithHmacSHA1").generateSecret(spec).encoded
        return android.util.Base64.encodeToString(key, android.util.Base64.NO_WRAP)
    }
}
