package dev.litebrowser

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.app.DownloadManager
import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.pm.PackageManager
import android.provider.MediaStore
import android.util.Base64
import android.webkit.MimeTypeMap
import java.io.File
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.Canvas
import android.text.Editable
import android.text.InputFilter
import android.text.TextUtils
import android.webkit.WebViewDatabase
import android.text.TextWatcher
import android.widget.ImageView
import android.widget.ScrollView
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.SslErrorHandler
import android.webkit.URLUtil
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import kotlin.concurrent.thread

class MainActivity : Activity() {

    /** One browser tab. */
    inner class Tab {
        val webView: WebView = WebView(this@MainActivity)
        var failedUrl: String? = null
        var errorToken: String? = null
        var retries = 0
        var pendingBlob: String? = null      // file name we're waiting for from a blob:/data: download
        var thumb: Bitmap? = null            // preview for the tab switcher
        var loading = false
        val shownUrl: String? get() = if (errorToken != null) failedUrl else webView.url
        val title: String
            get() = when {
                Web.isHome(webView.url) && errorToken == null -> "New Tab"
                errorToken != null -> Uri.parse(failedUrl ?: "").host ?: "Problem loading page"
                !webView.title.isNullOrBlank() && webView.title != webView.url -> webView.title!!
                else -> Uri.parse(webView.url ?: "").host ?: "New Tab"
            }
    }

    private val tabs = mutableListOf<Tab>()
    private var current: Tab? = null
    private lateinit var history: HistoryStore
    private val main = Handler(Looper.getMainLooper())

    private lateinit var frame: FrameLayout          // holds the browser and any overlay (tabs, menu, history)
    private lateinit var root: LinearLayout
    private lateinit var address: EditText
    private lateinit var lockIcon: ImageView
    private lateinit var actionIcon: ImageView
    private lateinit var backBtn: ImageView
    private lateinit var forwardBtn: ImageView
    private lateinit var tabsBtn: TextView
    private lateinit var bottomBar: LinearLayout
    private lateinit var findBar: LinearLayout
    private lateinit var findInput: EditText
    private lateinit var findCount: TextView
    private lateinit var container: FrameLayout
    private val overlays = mutableListOf<View>()
    private var lockView: View? = null
    private var backgroundedAt = 0L

    private var fileCallback: ValueCallback<Array<Uri>>? = null
    private var customView: View? = null
    private var customCallback: WebChromeClient.CustomViewCallback? = null

    private val prefs by lazy { getSharedPreferences("litebrowser", Context.MODE_PRIVATE) }
    private var desktopMode: Boolean
        get() = prefs.getBoolean("desktop", false)
        set(v) { prefs.edit().putBoolean("desktop", v).apply() }

    private val night get() = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    private val barColor get() = if (night) 0xFF1F1F22.toInt() else Color.WHITE
    private val fieldColor get() = if (night) 0xFF2C2C31.toInt() else 0xFFF0F1F4.toInt()
    private val textColor get() = if (night) 0xFFE8E8EA.toInt() else 0xFF1C1C1E.toInt()
    private val mutedColor get() = if (night) 0xFF9CA3AF.toInt() else 0xFF6B7280.toInt()
    private val accentColor get() = if (night) 0xFF60A5FA.toInt() else 0xFF2563EB.toInt()
    private val cardColor get() = if (night) 0xFF2A2A2E.toInt() else Color.WHITE
    private val surfaceColor get() = if (night) 0xFF161618.toInt() else 0xFFF2F3F5.toInt()
    private val lineColor get() = if (night) 0x22FFFFFF else 0x1A000000

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    // -----------------------------------------------------------------------------------------
    // Setup
    // -----------------------------------------------------------------------------------------

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        history = HistoryStore(this)
        buildUi()
        val start = urlFromIntent(intent) ?: Web.HOME
        applyRecentsPrivacy()
        if (AppLock.isEnabled(this)) showLock { newTab(start) }   // nothing loads until the PIN is right
        else newTab(start)
        main.postDelayed({ if (lockView == null) checkForUpdate(manual = false) }, 4000)
    }

    // -----------------------------------------------------------------------------------------
    // In-app updates (from GitHub Releases)
    // -----------------------------------------------------------------------------------------

    private val currentVersion: String
        get() = runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull() ?: "0"
    private var pendingApk: File? = null

    private fun isNewer(a: String, b: String): Boolean {
        val x = a.split('.').map { it.toIntOrNull() ?: 0 }
        val y = b.split('.').map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(x.size, y.size)) {
            val d = x.getOrElse(i) { 0 } - y.getOrElse(i) { 0 }
            if (d != 0) return d > 0
        }
        return false
    }

    /** Looks for a newer release. Automatic checks happen at most once a day. */
    private fun checkForUpdate(manual: Boolean) {
        val now = System.currentTimeMillis()
        if (!manual) {
            if (now - prefs.getLong("lastUpdateCheck", 0) < 24 * 3600_000L) return
            prefs.edit().putLong("lastUpdateCheck", now).apply()
        }
        val repo = getString(R.string.update_repo)
        thread {
            val result = runCatching {
                val c = URL("https://api.github.com/repos/$repo/releases/latest").openConnection() as HttpURLConnection
                c.connectTimeout = 10_000
                c.readTimeout = 10_000
                c.setRequestProperty("Accept", "application/vnd.github+json")
                val json = JSONObject(c.inputStream.bufferedReader().use { it.readText() })
                val tag = json.getString("tag_name").removePrefix("v")
                var apk: String? = null
                val assets = json.optJSONArray("assets") ?: JSONArray()
                for (i in 0 until assets.length()) {
                    val a = assets.getJSONObject(i)
                    if (a.optString("name").endsWith(".apk")) apk = a.optString("browser_download_url")
                }
                tag to apk
            }
            main.post {
                result.onSuccess { (tag, apk) ->
                    if (apk != null && isNewer(tag, currentVersion)) {
                        if (!manual && prefs.getString("skippedUpdate", "") == tag) return@onSuccess
                        AlertDialog.Builder(this)
                            .setTitle("Update available")
                            .setMessage("LiteBrowser $tag is ready (you have $currentVersion). It downloads inside the app and keeps your history and logins.")
                            .setPositiveButton("Update now") { _, _ -> downloadUpdate(tag, apk) }
                            .setNegativeButton("Later") { _, _ -> if (!manual) prefs.edit().putString("skippedUpdate", tag).apply() }
                            .show()
                    } else if (manual) {
                        AlertDialog.Builder(this).setTitle("You're up to date")
                            .setMessage("LiteBrowser $currentVersion is the newest version.")
                            .setPositiveButton("OK", null).show()
                    }
                }.onFailure { if (manual) toast("Couldn't check for updates. Check your connection.") }
            }
        }
    }

    /** Downloads the new APK with a progress bar, then opens the installer. */
    private fun downloadUpdate(version: String, url: String) {
        var cancelled = false
        val bar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply { max = 100; isIndeterminate = true }
        val status = label("Starting download…", 13f, mutedColor).apply { setPadding(0, dp(8), 0, 0) }
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(12), dp(24), 0)
            addView(bar)
            addView(status)
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle("Downloading LiteBrowser $version")
            .setView(box)
            .setCancelable(false)
            .setNegativeButton("Cancel") { _, _ -> cancelled = true }
            .show()
        thread {
            try {
                val dir = File(cacheDir, "updates").apply { mkdirs(); listFiles()?.forEach { it.delete() } }
                val out = File(dir, "LiteBrowser-$version.apk")
                val c = URL(url).openConnection() as HttpURLConnection
                c.instanceFollowRedirects = true
                c.connectTimeout = 15_000
                c.readTimeout = 30_000
                val total = c.contentLengthLong
                var done = 0L
                var lastShown = 0L
                c.inputStream.use { input ->
                    out.outputStream().use { output ->
                        val buf = ByteArray(64 * 1024)
                        while (true) {
                            if (cancelled) throw InterruptedException("cancelled")
                            val n = input.read(buf)
                            if (n < 0) break
                            output.write(buf, 0, n)
                            done += n
                            if (done - lastShown > 128 * 1024) {
                                lastShown = done
                                val d = done
                                main.post {
                                    if (total > 0) { bar.isIndeterminate = false; bar.progress = (d * 100 / total).toInt() }
                                    status.text = if (total > 0) "%.1f MB of %.1f MB".format(d / 1e6, total / 1e6) else "%.1f MB".format(d / 1e6)
                                }
                            }
                        }
                    }
                }
                main.post { dialog.dismiss(); installApk(out) }
            } catch (e: Exception) {
                main.post {
                    dialog.dismiss()
                    if (!cancelled) toast("Update download failed: ${e.message}")
                }
            }
        }
    }

    private fun installApk(file: File) {
        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
            pendingApk = file
            AlertDialog.Builder(this)
                .setTitle("One-time permission")
                .setMessage("To install updates, allow LiteBrowser to install apps: turn on “Allow from this source”, then come back. The update continues by itself.")
                .setPositiveButton("Open settings") { _, _ ->
                    try { startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))) }
                    catch (_: Exception) { startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS)) }
                }
                .setNegativeButton("Cancel") { _, _ -> pendingApk = null }
                .show()
            return
        }
        val uri = Uri.parse("content://dev.litebrowser.updates/${file.name}")
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        try { startActivity(intent) } catch (_: Exception) { toast("Couldn't open the installer") }
    }

    override fun onResume() {
        super.onResume()
        val apk = pendingApk ?: return
        if (Build.VERSION.SDK_INT < 26 || packageManager.canRequestPackageInstalls()) {
            pendingApk = null
            installApk(apk)
        }
    }

    override fun onStop() {
        super.onStop()
        backgroundedAt = System.currentTimeMillis()
    }

    override fun onStart() {
        super.onStart()
        // Coming back after more than a minute away: ask for the PIN again.
        if (AppLock.isEnabled(this) && lockView == null && backgroundedAt > 0 &&
            System.currentTimeMillis() - backgroundedAt > 60_000) {
            showLock { }
        }
    }

    /** Hide page contents from the Recent apps screen while PIN lock is on (Android 13+). */
    private fun applyRecentsPrivacy() {
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(!AppLock.isEnabled(this))
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val url = urlFromIntent(intent) ?: return
        if (lockView != null) pendingUrl = url else newTab(url)
    }

    private var pendingUrl: String? = null

    // -----------------------------------------------------------------------------------------
    // PIN lock
    // -----------------------------------------------------------------------------------------

    private fun showLock(onUnlock: () -> Unit) {
        if (lockView != null) return
        hideKeyboard()
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(32), 0, dp(32), 0)
        }
        val logo = ImageView(this).apply { setImageResource(R.mipmap.ic_launcher) }
        box.addView(logo, LinearLayout.LayoutParams(dp(84), dp(84)).apply { bottomMargin = dp(18) })
        box.addView(label("LiteBrowser is locked", 22f, textColor, true).apply { gravity = Gravity.CENTER })
        box.addView(label("Enter your PIN to continue", 15f, mutedColor).apply { gravity = Gravity.CENTER; setPadding(0, dp(6), 0, dp(22)) })
        val pin = EditText(this).apply {
            inputType = android.text.InputType.TYPE_CLASS_NUMBER or android.text.InputType.TYPE_NUMBER_VARIATION_PASSWORD
            filters = arrayOf(InputFilter.LengthFilter(10))
            gravity = Gravity.CENTER
            textSize = 24f
            letterSpacing = 0.3f
            setTextColor(textColor)
            setHintTextColor(mutedColor)
            hint = "PIN"
            background = rounded(fieldColor, 16)
            setPadding(dp(16), dp(12), dp(16), dp(12))
            imeOptions = EditorInfo.IME_ACTION_DONE
        }
        box.addView(pin, LinearLayout.LayoutParams(dp(240), ViewGroup.LayoutParams.WRAP_CONTENT))
        val message = label("", 14f, 0xFFDC2626.toInt()).apply { gravity = Gravity.CENTER; setPadding(0, dp(14), 0, 0) }
        val unlock = label("Unlock", 16f, Color.WHITE, true).apply {
            gravity = Gravity.CENTER
            background = rounded(accentColor, 24)
            setPadding(dp(16), dp(14), dp(16), dp(14))
        }
        box.addView(unlock, LinearLayout.LayoutParams(dp(240), ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(16) })
        box.addView(message, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        val screen = FrameLayout(this).apply {
            setBackgroundColor(barColor)
            isClickable = true                       // blocks touches to the browser underneath
            isFocusable = true
            addView(box, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        }

        fun attempt() {
            val entered = pin.text.toString()
            if (entered.isEmpty()) return
            pin.setText("")
            if (AppLock.verify(this, entered)) {
                AppLock.setFailures(this, 0)
                AppLock.setPinLength(this, entered.length)   // PINs set before 1.0.9 learn their length here
                hideKeyboard()
                frame.removeView(screen)
                lockView = null
                onUnlock()
                pendingUrl?.let { newTab(it); pendingUrl = null }
                return
            }
            val fails = AppLock.failures(this) + 1
            AppLock.setFailures(this, fails)
            if (fails >= AppLock.MAX_FAILURES) {
                frame.removeView(screen)
                lockView = null
                factoryReset()
                return
            }
            // no message: just a shake
            pin.animate().translationX(dp(12).toFloat()).setDuration(50).withEndAction {
                pin.animate().translationX(-dp(12).toFloat()).setDuration(50).withEndAction {
                    pin.animate().translationX(0f).setDuration(50).start()
                }.start()
            }.start()
        }
        unlock.setOnClickListener { attempt() }
        pin.setOnEditorActionListener { _, _, _ -> attempt(); true }
        // Like a phone passcode: check as soon as the last digit is typed (counts as an attempt)
        pin.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) {
                val n = AppLock.pinLength(this@MainActivity)
                if (n > 0 && (s?.length ?: 0) == n) pin.post { if (pin.text.length == n) attempt() }
            }
        })

        lockView = screen
        frame.addView(screen, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        pin.requestFocus()
        showKeyboard(pin)
    }

    /** Two wrong PINs: erase everything and start like the very first launch. Downloaded files stay. */
    private fun factoryReset() {
        overlays.toList().forEach { frame.removeView(it) }
        overlays.clear()
        findBar.visibility = View.GONE
        tabs.forEach {
            container.removeView(it.webView)
            it.webView.clearCache(true)
            it.webView.clearHistory()
            it.webView.destroy()
        }
        tabs.clear()
        current = null
        CookieManager.getInstance().removeAllCookies(null)
        CookieManager.getInstance().flush()
        WebStorage.getInstance().deleteAllData()
        WebViewDatabase.getInstance(this).clearHttpAuthUsernamePassword()
        history.clearHistory()
        history.clearSearches()
        history.hidden = emptySet()
        getSharedPreferences("litebrowser", Context.MODE_PRIVATE).edit().clear().commit()
        AppLock.disable(this)
        applyRecentsPrivacy()
        pendingUrl = null
        newTab(Web.HOME)
    }

    /** Menu › App lock: turn on, change, turn off, or lock now. */
    private fun showPinSettings() {
        fun pinField(hintText: String) = EditText(this).apply {
            inputType = android.text.InputType.TYPE_CLASS_NUMBER or android.text.InputType.TYPE_NUMBER_VARIATION_PASSWORD
            filters = arrayOf(InputFilter.LengthFilter(10))
            hint = hintText
        }
        fun form(vararg views: View) = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(22), dp(8), dp(22), 0)
            views.forEach { addView(it) }
        }
        val warning = "If a wrong PIN is entered 2 times in a row, LiteBrowser erases all history, searches, sign-ins, " +
            "site data, tabs and settings, and starts fresh. Downloaded files are kept. A forgotten PIN can't be recovered."

        if (!AppLock.isEnabled(this)) {
            val p1 = pinField("New PIN (4–10 digits)")
            val p2 = pinField("Confirm PIN")
            AlertDialog.Builder(this)
                .setTitle("Turn on PIN lock")
                .setView(form(label(warning, 13f, mutedColor).apply { setPadding(0, 0, 0, dp(8)) }, p1, p2))
                .setPositiveButton("Turn on") { _, _ ->
                    val a = p1.text.toString(); val b = p2.text.toString()
                    when {
                        !AppLock.isValidFormat(a) -> toast("Use 4 to 10 digits")
                        a != b -> toast("The PINs don't match")
                        else -> { AppLock.set(this, a); applyRecentsPrivacy(); toast("PIN lock is on") }
                    }
                }
                .setNegativeButton("Cancel", null)
                .show()
            return
        }
        AlertDialog.Builder(this)
            .setTitle("PIN lock is on")
            .setItems(arrayOf("Lock now", "Change PIN", "Turn off PIN lock")) { _, which ->
                when (which) {
                    0 -> showLock { }
                    1 -> {
                        val cur = pinField("Current PIN"); val p1 = pinField("New PIN (4–10 digits)"); val p2 = pinField("Confirm new PIN")
                        AlertDialog.Builder(this).setTitle("Change PIN").setView(form(cur, p1, p2))
                            .setPositiveButton("Change") { _, _ ->
                                when {
                                    !AppLock.verify(this, cur.text.toString()) -> toast("Current PIN is wrong")
                                    !AppLock.isValidFormat(p1.text.toString()) -> toast("Use 4 to 10 digits")
                                    p1.text.toString() != p2.text.toString() -> toast("The new PINs don't match")
                                    else -> { AppLock.set(this, p1.text.toString()); toast("PIN changed") }
                                }
                            }
                            .setNegativeButton("Cancel", null).show()
                    }
                    2 -> {
                        val cur = pinField("Current PIN")
                        AlertDialog.Builder(this).setTitle("Turn off PIN lock").setView(form(cur))
                            .setPositiveButton("Turn off") { _, _ ->
                                if (AppLock.verify(this, cur.text.toString())) { AppLock.disable(this); applyRecentsPrivacy(); toast("PIN lock is off") }
                                else toast("Wrong PIN")
                            }
                            .setNegativeButton("Cancel", null).show()
                    }
                }
            }
            .setNegativeButton("Close", null)
            .show()
    }

    private fun urlFromIntent(i: Intent?): String? {
        if (i == null) return null
        if (i.action == Intent.ACTION_WEB_SEARCH) i.getStringExtra("query")?.let { return Web.resolveInput(it) }
        return i.dataString
    }

    private fun buildUi() {
        frame = FrameLayout(this).apply { setBackgroundColor(barColor) }
        root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(barColor) }

        // ---- Top: rounded address bar (lock · address · reload/clear)
        lockIcon = icon(R.drawable.ic_search, 18, mutedColor)
        actionIcon = icon(R.drawable.ic_refresh, 20, textColor).apply {
            setPadding(dp(8), dp(8), dp(8), dp(8))
            background = ripple(true)
            setOnClickListener { onAddressAction() }
        }
        address = EditText(this).apply {
            hint = "Search Google or type a URL"
            setSingleLine(true)
            textSize = 15.5f
            setTextColor(textColor)
            setHintTextColor(mutedColor)
            background = null
            ellipsize = TextUtils.TruncateAt.END
            imeOptions = EditorInfo.IME_ACTION_GO
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_URI
            setSelectAllOnFocus(true)
            setPadding(dp(8), 0, dp(4), 0)
            setOnEditorActionListener { _, actionId, event ->
                val go = actionId == EditorInfo.IME_ACTION_GO ||
                    (event != null && event.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_DOWN)
                if (go) { submitAddress(); true } else false
            }
            setOnFocusChangeListener { _, focused ->
                if (focused) {
                    setText(current?.shownUrl?.takeUnless { Web.isHome(it) } ?: "")
                    selectAll()
                    bottomBar.visibility = View.GONE            // more room while typing, like Chrome
                } else {
                    bottomBar.visibility = View.VISIBLE
                    updateChrome()
                }
                updateAddressIcons()
            }
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun afterTextChanged(s: Editable?) { updateAddressIcons() }
            })
        }
        val pill = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = rounded(fieldColor, 24)
            setPadding(dp(14), 0, dp(4), 0)
            addView(lockIcon, LinearLayout.LayoutParams(dp(18), dp(18)))
            addView(address, LinearLayout.LayoutParams(0, dp(46), 1f))
            addView(actionIcon, LinearLayout.LayoutParams(dp(38), dp(38)))
            setOnClickListener { address.requestFocus(); showKeyboard(address) }
        }
        val topBar = LinearLayout(this).apply {
            setPadding(dp(12), dp(8), dp(12), dp(8))
            addView(pill, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(46)))
        }

        // ---- Find in page bar (hidden until used)
        findInput = EditText(this).apply {
            hint = "Find in page"
            setSingleLine(true)
            textSize = 15f
            setTextColor(textColor)
            setHintTextColor(mutedColor)
            background = null
            imeOptions = EditorInfo.IME_ACTION_SEARCH
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun afterTextChanged(s: Editable?) {
                    val q = s?.toString() ?: ""
                    if (q.isEmpty()) { current?.webView?.clearMatches(); findCount.text = "" }
                    else current?.webView?.findAllAsync(q)
                }
            })
            setOnEditorActionListener { _, _, _ -> current?.webView?.findNext(true); true }
        }
        findCount = TextView(this).apply { textSize = 13f; setTextColor(mutedColor); setPadding(dp(6), 0, dp(6), 0) }
        findBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            visibility = View.GONE
            setPadding(dp(16), dp(2), dp(8), dp(6))
            addView(icon(R.drawable.ic_find, 20, mutedColor), LinearLayout.LayoutParams(dp(20), dp(20)))
            addView(findInput, LinearLayout.LayoutParams(0, dp(44), 1f))
            addView(findCount)
            addView(barButton(R.drawable.ic_up) { current?.webView?.findNext(false) }, LinearLayout.LayoutParams(dp(42), dp(42)))
            addView(barButton(R.drawable.ic_down) { current?.webView?.findNext(true) }, LinearLayout.LayoutParams(dp(42), dp(42)))
            addView(barButton(R.drawable.ic_close) { hideFind() }, LinearLayout.LayoutParams(dp(42), dp(42)))
        }

        container = FrameLayout(this)

        // ---- Bottom bar: back · forward · home · tabs · menu (within thumb reach)
        backBtn = barButton(R.drawable.ic_back) { current?.webView?.takeIf { w -> w.canGoBack() }?.goBack() }
        forwardBtn = barButton(R.drawable.ic_forward) { current?.webView?.takeIf { w -> w.canGoForward() }?.goForward() }
        val homeBtn = barButton(R.drawable.ic_home) { current?.webView?.loadUrl(Web.HOME) }
        tabsBtn = TextView(this).apply {
            gravity = Gravity.CENTER
            textSize = 12f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(textColor)
            background = GradientDrawable().apply { cornerRadius = dp(6).toFloat(); setStroke(dp(2), textColor) }
        }
        val tabsSlot = FrameLayout(this).apply {
            background = ripple(true)
            addView(tabsBtn, FrameLayout.LayoutParams(dp(23), dp(23), Gravity.CENTER))
            setOnClickListener { showTabSwitcher() }
        }
        val menuBtn = barButton(R.drawable.ic_more) { showMenuSheet() }
        bottomBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), 0, dp(8), 0)
            for (v in listOf(backBtn, forwardBtn, homeBtn, tabsSlot, menuBtn)) {
                addView(v, LinearLayout.LayoutParams(0, dp(54), 1f))
            }
        }
        val divider = View(this).apply { setBackgroundColor(lineColor) }

        root.addView(topBar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        root.addView(findBar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        root.addView(container, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(divider, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1))
        root.addView(bottomBar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        frame.addView(root, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        setContentView(frame)
        applySystemBars()
    }

    // ---- Small UI helpers

    private fun icon(res: Int, sizeDp: Int, tint: Int) = ImageView(this).apply {
        setImageResource(res)
        imageTintList = ColorStateList.valueOf(tint)
        scaleType = ImageView.ScaleType.FIT_CENTER
        minimumWidth = dp(sizeDp)
        minimumHeight = dp(sizeDp)
    }

    private fun barButton(res: Int, onClick: () -> Unit) = icon(res, 24, textColor).apply {
        setPadding(dp(12), dp(12), dp(12), dp(12))
        background = ripple(true)
        setOnClickListener { onClick() }
    }

    private fun ripple(borderless: Boolean): android.graphics.drawable.Drawable? {
        val tv = TypedValue()
        val attr = if (borderless) android.R.attr.selectableItemBackgroundBorderless else android.R.attr.selectableItemBackground
        theme.resolveAttribute(attr, tv, true)
        return getDrawable(tv.resourceId)
    }

    private fun rounded(color: Int, radiusDp: Int, stroke: Int? = null) = GradientDrawable().apply {
        cornerRadius = dp(radiusDp).toFloat()
        setColor(color)
        if (stroke != null) setStroke(dp(2), stroke)
    }

    private fun label(text: String, sizeSp: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
        this.text = text
        textSize = sizeSp
        setTextColor(color)
        if (bold) setTypeface(typeface, Typeface.BOLD)
    }

    private fun showKeyboard(v: View) {
        main.postDelayed({ (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(v, InputMethodManager.SHOW_IMPLICIT) }, 120)
    }

    private fun hideKeyboard() {
        (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(frame.windowToken, 0)
    }

    /** Edge-to-edge on Android 15+: keep content below the status bar and above the keyboard / nav bar. */
    private fun applySystemBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            frame.setOnApplyWindowInsetsListener { v, insets ->
                val b = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.ime() or WindowInsets.Type.displayCutout())
                v.setPadding(b.left, b.top, b.right, b.bottom)
                insets
            }
            window.insetsController?.setSystemBarsAppearance(
                if (night) 0 else WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
                WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS)
        } else {
            @Suppress("DEPRECATION")
            run {
                window.statusBarColor = barColor
                window.navigationBarColor = barColor
                if (!night) window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
            }
        }
    }

    // -----------------------------------------------------------------------------------------
    // Tabs
    // -----------------------------------------------------------------------------------------

    /**
     * Passkeys and security keys: sites can ask for a passkey, and Android shows its own sheet
     * (this phone's passkeys, a password manager, or "use another device" with a QR code).
     * Needs an up-to-date Android System WebView; quietly does nothing on older ones.
     */
    private fun enablePasskeys(wv: WebView) {
        try {
            if (androidx.webkit.WebViewFeature.isFeatureSupported(androidx.webkit.WebViewFeature.WEB_AUTHENTICATION)) {
                androidx.webkit.WebSettingsCompat.setWebAuthenticationSupport(
                    wv.settings, androidx.webkit.WebSettingsCompat.WEB_AUTHENTICATION_SUPPORT_FOR_BROWSER)
            }
        } catch (_: Throwable) { }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun newTab(url: String?, activate: Boolean = true, popup: Message? = null): Tab {
        val tab = Tab()
        val wv = tab.webView
        wv.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            loadWithOverviewMode = true
            useWideViewPort = true
            builtInZoomControls = true
            displayZoomControls = false
            setSupportMultipleWindows(true)
            javaScriptCanOpenWindowsAutomatically = false
            mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
            mediaPlaybackRequiresUserGesture = true
            if (desktopMode) userAgentString = DESKTOP_UA
        }
        enablePasskeys(wv)
        CookieManager.getInstance().setAcceptThirdPartyCookies(wv, true)
        wv.addJavascriptInterface(Bridge(tab), "LiteAndroid")
        wv.webViewClient = TabClient(tab)
        wv.webChromeClient = TabChrome(tab)
        wv.setDownloadListener { dlUrl, ua, disposition, mime, _ -> download(tab, dlUrl, ua, disposition, mime) }
        wv.setFindListener { active, count, _ ->
            if (tab === current) findCount.text = if (count == 0) "0/0" else "${active + 1}/$count"
        }

        val index = current?.let { tabs.indexOf(it) + 1 } ?: tabs.size
        tabs.add(index.coerceIn(0, tabs.size), tab)
        if (popup != null) {
            (popup.obj as WebView.WebViewTransport).webView = wv
            popup.sendToTarget()
        } else if (url != null) {
            wv.loadUrl(url)
        }
        if (activate || current == null) switchTo(tab) else updateChrome()
        return tab
    }

    private fun switchTo(tab: Tab) {
        current?.let { if (it !== tab) captureThumb(it) }
        current?.webView?.let { container.removeView(it) }
        current = tab
        (tab.webView.parent as? ViewGroup)?.removeView(tab.webView)
        container.addView(tab.webView, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        tab.webView.requestFocus()
        pushHome(tab)
        updateChrome()
    }

    private fun closeTab(tab: Tab) {
        val i = tabs.indexOf(tab)
        if (i < 0) return
        tabs.removeAt(i)
        if (current === tab) {
            container.removeView(tab.webView)
            current = null
            if (tabs.isEmpty()) newTab(Web.HOME) else switchTo(tabs[(i - 1).coerceAtLeast(0)])
        }
        tab.webView.destroy()
        updateChrome()
    }

    /** Takes a small screenshot of a tab for the tab switcher. */
    private fun captureThumb(tab: Tab) {
        val wv = tab.webView
        if (wv.width <= 0 || wv.height <= 0) return
        try {
            val scale = 0.4f
            val bmp = Bitmap.createBitmap((wv.width * scale).toInt(), (wv.height * scale).toInt(), Bitmap.Config.RGB_565)
            val c = Canvas(bmp)
            c.scale(scale, scale)
            c.translate(-wv.scrollX.toFloat(), -wv.scrollY.toFloat())
            wv.draw(c)
            tab.thumb = bmp
        } catch (_: Throwable) {
        }
    }

    // -----------------------------------------------------------------------------------------
    // Overlays: tab switcher, menu sheet, history page
    // -----------------------------------------------------------------------------------------

    private fun addOverlay(v: View) {
        hideKeyboard()
        address.clearFocus()
        overlays += v
        frame.addView(v, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        v.alpha = 0f
        v.animate().alpha(1f).setDuration(160).start()
    }

    private fun closeOverlay(v: View) {
        overlays.remove(v)
        v.animate().alpha(0f).setDuration(140).withEndAction { frame.removeView(v) }.start()
    }

    private fun closeTopOverlay(): Boolean {
        val top = overlays.lastOrNull() ?: return false
        closeOverlay(top)
        return true
    }

    /** Full-screen page with a header (← title … action). Returns (page, content area). */
    private fun overlayPage(title: String, action: String? = null, onAction: (() -> Unit)? = null): Pair<LinearLayout, LinearLayout> {
        val page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(surfaceColor)
            isClickable = true
        }
        val header = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), dp(6), dp(12), dp(6))
            setBackgroundColor(barColor)
        }
        header.addView(barButton(R.drawable.ic_back) { closeOverlay(page) }, LinearLayout.LayoutParams(dp(48), dp(48)))
        header.addView(label(title, 19f, textColor, true), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        if (action != null && onAction != null) {
            header.addView(label(action, 15f, accentColor, true).apply {
                setPadding(dp(12), dp(10), dp(12), dp(10))
                background = ripple(false)
                setOnClickListener { onAction() }
            })
        }
        page.addView(header)
        val body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        page.addView(body, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        return page to body
    }

    private fun showTabSwitcher() {
        current?.let { captureThumb(it) }
        lateinit var page: LinearLayout
        val pair = overlayPage("${tabs.size} tab${if (tabs.size == 1) "" else "s"}", "Close all") {
            tabs.toList().forEach { container.removeView(it.webView); it.webView.destroy() }
            tabs.clear(); current = null
            newTab(Web.HOME)
            closeOverlay(page)
        }
        page = pair.first
        val body = pair.second
        val wrapper = FrameLayout(this)
        val grid = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(10), dp(10), dp(10), dp(96))
        }
        for (row in tabs.chunked(2)) {
            val line = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            for (tab in row) line.addView(tabCard(tab) { closeOverlay(page) }, LinearLayout.LayoutParams(0, dp(250), 1f).apply { setMargins(dp(6), dp(6), dp(6), dp(6)) })
            if (row.size == 1) line.addView(View(this), LinearLayout.LayoutParams(0, dp(250), 1f).apply { setMargins(dp(6), dp(6), dp(6), dp(6)) })
            grid.addView(line)
        }
        wrapper.addView(ScrollView(this).apply { addView(grid) })
        val fab = ImageView(this).apply {
            setImageResource(R.drawable.ic_plus)
            imageTintList = ColorStateList.valueOf(Color.WHITE)
            setPadding(dp(16), dp(16), dp(16), dp(16))
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(accentColor) }
            elevation = dp(6).toFloat()
            contentDescription = "New tab"
            setOnClickListener { closeOverlay(page); newTab(Web.HOME); focusAddress() }
        }
        wrapper.addView(fab, FrameLayout.LayoutParams(dp(60), dp(60), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply { bottomMargin = dp(24) })
        body.addView(wrapper, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        addOverlay(page)
    }

    private fun tabCard(tab: Tab, dismiss: () -> Unit): View {
        val isCurrent = tab === current
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(cardColor, 16, if (isCurrent) accentColor else null)
            elevation = dp(2).toFloat()
            clipToOutline = true
            setPadding(dp(2), dp(2), dp(2), dp(2))
            setOnClickListener { switchTo(tab); dismiss() }
        }
        val head = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(4), dp(2), dp(4))
        }
        head.addView(label(tab.title, 13f, textColor, true).apply { setSingleLine(true); ellipsize = TextUtils.TruncateAt.END },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        head.addView(icon(R.drawable.ic_close, 16, mutedColor).apply {
            setPadding(dp(10), dp(10), dp(10), dp(10))
            background = ripple(true)
            setOnClickListener {
                closeTab(tab)
                dismiss()
                if (tabs.isNotEmpty()) showTabSwitcher()
            }
        }, LinearLayout.LayoutParams(dp(38), dp(38)))
        card.addView(head)
        val preview: View = tab.thumb?.let { bmp ->
            ImageView(this).apply { setImageBitmap(bmp); scaleType = ImageView.ScaleType.CENTER_CROP }
        } ?: FrameLayout(this).apply {
            setBackgroundColor(surfaceColor)
            addView(icon(if (Web.isHome(tab.webView.url)) R.drawable.ic_home else R.drawable.ic_globe, 32, mutedColor),
                FrameLayout.LayoutParams(dp(32), dp(32), Gravity.CENTER))
        }
        card.addView(preview, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        return card
    }

    /** Menu that slides up from the bottom with an icon grid. */
    private fun showMenuSheet() {
        val scrim = FrameLayout(this).apply { setBackgroundColor(0x73000000) }
        val sheet = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                setColor(barColor)
                cornerRadii = floatArrayOf(dp(22).toFloat(), dp(22).toFloat(), dp(22).toFloat(), dp(22).toFloat(), 0f, 0f, 0f, 0f)
            }
            setPadding(dp(12), dp(8), dp(12), dp(16))
            isClickable = true
        }
        val handle = View(this).apply { background = rounded(lineColor or 0x33000000, 3) }
        sheet.addView(handle, LinearLayout.LayoutParams(dp(40), dp(5)).apply { gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = dp(10) })

        val tab = current
        val url = tab?.shownUrl
        if (tab != null && url != null && !Web.isHome(url)) {
            val head = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(10), dp(4), dp(10), dp(12)) }
            head.addView(label(tab.title, 15f, textColor, true).apply { setSingleLine(true); ellipsize = TextUtils.TruncateAt.END })
            head.addView(label(Uri.parse(url).host ?: url, 13f, mutedColor).apply { setSingleLine(true) })
            sheet.addView(head)
        }

        fun dismiss() {
            sheet.animate().translationY(sheet.height.toFloat()).setDuration(160).start()
            closeOverlay(scrim)
        }
        class SheetItem(val icon: Int, val text: String, val on: Boolean = false, val action: () -> Unit)
        val items = listOf(
            SheetItem(R.drawable.ic_plus, "New tab") { newTab(Web.HOME); focusAddress() },
            SheetItem(R.drawable.ic_history, "History") { showHistoryPage(false) },
            SheetItem(R.drawable.ic_download, "Downloads") { openDownloads() },
            SheetItem(R.drawable.ic_find, "Find in page") { showFind() },
            SheetItem(R.drawable.ic_share, "Share") { sharePage() },
            SheetItem(R.drawable.ic_desktop, "Desktop site", desktopMode) { toggleDesktop() },
            SheetItem(R.drawable.ic_refresh, "Reload") { current?.let { t -> if (t.errorToken != null) t.failedUrl?.let { u -> t.webView.loadUrl(u) } else t.webView.reload() } },
            SheetItem(R.drawable.ic_search, "Searches") { showHistoryPage(true) },
            SheetItem(R.drawable.ic_trash, "Clear data") { showClearData() },
            SheetItem(R.drawable.ic_globe, "DNS") { showDnsHelp() },
            SheetItem(R.drawable.ic_lock, "App lock", AppLock.isEnabled(this)) { showPinSettings() },
            SheetItem(R.drawable.ic_info, "About") { showAbout() },
        )
        for (row in items.chunked(4)) {
            val line = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            for (item in row) {
                val cell = LinearLayout(this).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER
                    setPadding(0, dp(12), 0, dp(12))
                    background = ripple(false)
                    setOnClickListener { dismiss(); main.postDelayed({ item.action() }, 120) }
                }
                val ic = icon(item.icon, 24, if (item.on) Color.WHITE else textColor).apply {
                    setPadding(dp(12), dp(12), dp(12), dp(12))
                    background = rounded(if (item.on) accentColor else fieldColor, 16)
                }
                cell.addView(ic, LinearLayout.LayoutParams(dp(50), dp(50)))
                cell.addView(label(item.text, 12f, textColor).apply { gravity = Gravity.CENTER; setPadding(0, dp(6), 0, 0); setSingleLine(true) })
                line.addView(cell, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            }
            repeat(4 - row.size) { line.addView(View(this), LinearLayout.LayoutParams(0, 1, 1f)) }
            sheet.addView(line)
        }
        scrim.addView(sheet, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
        scrim.setOnClickListener { dismiss() }
        addOverlay(scrim)
        sheet.translationY = dp(400).toFloat()
        sheet.animate().translationY(0f).setDuration(220).start()
    }

    /** History (or search history) as a full page with a search box. */
    private fun showHistoryPage(searches: Boolean) {
        lateinit var page: LinearLayout
        lateinit var render: () -> Unit
        val pair = overlayPage(if (searches) "Search history" else "History", "Clear") {
            AlertDialog.Builder(this)
                .setMessage(if (searches) "Clear all your searches?" else "Clear all browsing history?")
                .setPositiveButton("Clear") { _, _ ->
                    if (searches) history.clearSearches() else { history.clearHistory(); tabs.forEach { it.webView.clearHistory() } }
                    render()
                    current?.let { pushHome(it) }
                }
                .setNegativeButton("Cancel", null)
                .show()
        }
        page = pair.first
        val body = pair.second
        val search = EditText(this).apply {
            hint = if (searches) "Filter searches" else "Search history"
            setSingleLine(true)
            textSize = 15f
            setTextColor(textColor)
            setHintTextColor(mutedColor)
            background = rounded(fieldColor, 22)
            setPadding(dp(16), dp(10), dp(16), dp(10))
        }
        body.addView(search, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { setMargins(dp(14), dp(10), dp(14), dp(6)) })
        val list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(0, 0, 0, dp(24)) }
        body.addView(ScrollView(this).apply { addView(list) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        val dayFmt = java.text.SimpleDateFormat("EEEE, d MMMM", java.util.Locale.getDefault())
        val timeFmt = android.text.format.DateFormat.getTimeFormat(this)
        fun dayLabel(t: Long): String {
            val days = ((System.currentTimeMillis() / 86_400_000L) - (t / 86_400_000L)).toInt()
            return when (days) { 0 -> "Today"; 1 -> "Yesterday"; else -> dayFmt.format(java.util.Date(t)) }
        }
        fun row(title: String, sub: String, iconRes: Int, onClick: () -> Unit): View = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(18), dp(10), dp(18), dp(10))
            background = ripple(false)
            setOnClickListener { onClick() }
            addView(icon(iconRes, 20, mutedColor), LinearLayout.LayoutParams(dp(20), dp(20)))
            val texts = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(16), 0, 0, 0) }
            texts.addView(label(title, 15f, textColor).apply { setSingleLine(true); ellipsize = TextUtils.TruncateAt.END })
            if (sub.isNotEmpty()) texts.addView(label(sub, 12.5f, mutedColor).apply { setSingleLine(true); ellipsize = TextUtils.TruncateAt.END })
            addView(texts, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }

        render = {
            list.removeAllViews()
            val f = search.text.toString().trim().lowercase()
            var lastDay = ""
            var shown = 0
            if (searches) {
                for (it in history.searches) {
                    if (f.isNotEmpty() && !it.query.lowercase().contains(f)) continue
                    if (shown++ >= 400) break
                    val d = dayLabel(it.time)
                    if (d != lastDay) { lastDay = d; list.addView(label(d.uppercase(), 12f, mutedColor, true).apply { setPadding(dp(18), dp(16), dp(18), dp(6)) }) }
                    list.addView(row(it.query, timeFmt.format(java.util.Date(it.time)), R.drawable.ic_search) {
                        closeOverlay(page); current?.webView?.loadUrl(Web.googleSearch(it.query))
                    })
                }
            } else {
                for (it in history.items) {
                    val host = Uri.parse(it.url).host?.removePrefix("www.") ?: it.url
                    if (f.isNotEmpty() && !it.title.lowercase().contains(f) && !it.url.lowercase().contains(f)) continue
                    if (shown++ >= 400) break
                    val d = dayLabel(it.time)
                    if (d != lastDay) { lastDay = d; list.addView(label(d.uppercase(), 12f, mutedColor, true).apply { setPadding(dp(18), dp(16), dp(18), dp(6)) }) }
                    list.addView(row(it.title.ifBlank { host }, host + " · " + timeFmt.format(java.util.Date(it.time)), R.drawable.ic_globe) {
                        closeOverlay(page); current?.webView?.loadUrl(it.url)
                    })
                }
            }
            if (shown == 0) list.addView(label(if (f.isEmpty()) "Nothing here yet" else "No matches", 15f, mutedColor).apply {
                gravity = Gravity.CENTER; setPadding(0, dp(60), 0, 0)
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        search.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) { render() }
        })
        render()
        addOverlay(page)
    }

    // -----------------------------------------------------------------------------------------
    // Find in page
    // -----------------------------------------------------------------------------------------

    private fun showFind() {
        findBar.visibility = View.VISIBLE
        findInput.requestFocus()
        showKeyboard(findInput)
        if (findInput.text.isNotEmpty()) current?.webView?.findAllAsync(findInput.text.toString())
    }

    private fun hideFind() {
        findBar.visibility = View.GONE
        current?.webView?.clearMatches()
        findCount.text = ""
        hideKeyboard()
    }

    // -----------------------------------------------------------------------------------------
    // Address bar
    // -----------------------------------------------------------------------------------------

    private fun submitAddress() {
        val tab = current ?: return
        tab.webView.loadUrl(Web.resolveInput(address.text.toString()))
        address.clearFocus()
        hideKeyboard()
        tab.webView.requestFocus()
    }

    private fun focusAddress() {
        address.requestFocus()
        showKeyboard(address)
    }

    /** Lock / warning / search icon on the left, reload / stop / clear on the right. */
    private fun updateAddressIcons() {
        val tab = current
        val url = tab?.shownUrl
        val (res, tint) = when {
            address.hasFocus() || url == null || Web.isHome(url) -> R.drawable.ic_search to mutedColor
            url.startsWith("https://") -> R.drawable.ic_lock to mutedColor
            url.startsWith("http://") -> R.drawable.ic_warning to 0xFFF59E0B.toInt()
            else -> R.drawable.ic_globe to mutedColor
        }
        lockIcon.setImageResource(res)
        lockIcon.imageTintList = ColorStateList.valueOf(tint)
        val clear = address.hasFocus() && address.text.isNotEmpty()
        actionIcon.setImageResource(if (clear || tab?.loading == true) R.drawable.ic_close else R.drawable.ic_refresh)
        actionIcon.visibility = if (!address.hasFocus() && url != null && Web.isHome(url)) View.INVISIBLE else View.VISIBLE
    }

    private fun onAddressAction() {
        val tab = current ?: return
        when {
            address.hasFocus() -> address.setText("")
            tab.loading -> tab.webView.stopLoading()
            tab.errorToken != null -> tab.failedUrl?.let { tab.webView.loadUrl(it) }
            else -> tab.webView.reload()
        }
    }

    private fun updateChrome() {
        val tab = current ?: return
        if (!address.hasFocus()) {
            val url = tab.shownUrl
            address.setText(Web.googleQuery(url) ?: url?.let { u ->
                if (Web.isHome(u) || u.startsWith("about:") || u.startsWith("data:")) "" else Uri.parse(u).host?.removePrefix("www.") ?: u
            } ?: "")
        }
        backBtn.alpha = if (tab.webView.canGoBack()) 1f else 0.3f
        forwardBtn.alpha = if (tab.webView.canGoForward()) 1f else 0.3f
        tabsBtn.text = if (tabs.size > 99) ":)" else tabs.size.toString()
        updateAddressIcons()
    }

    // -----------------------------------------------------------------------------------------
    // Home page
    // -----------------------------------------------------------------------------------------

    private fun pushHome(tab: Tab) {
        if (!Web.isHome(tab.webView.url)) return
        val state = JSONObject()
            .put("sites", history.topSites(8))
            .put("recent", history.recent(5))
            .put("hidden", JSONArray(history.hidden.toList()))
            .put("name", "")
            .put("version", runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull() ?: "")
        tab.webView.evaluateJavascript("window.renderHome && renderHome($state)", null)
    }

    /** Messages from the home page and the error pages (window.LiteAndroid.post). */
    inner class Bridge(private val tab: Tab) {
        @JavascriptInterface
        fun post(json: String) {
            main.post { handleMessage(tab, json) }
        }

        /** Receives the bytes of a blob:/data: download (only when LiteBrowser asked for one). */
        @JavascriptInterface
        fun saveFile(mime: String, base64: String) {
            main.post {
                val name = tab.pendingBlob ?: return@post
                tab.pendingBlob = null
                if (base64.isEmpty()) { toast("Couldn't download this file"); return@post }
                runCatching { Base64.decode(base64, Base64.DEFAULT) }
                    .onSuccess { saveBytes(name, mime.ifBlank { "application/octet-stream" }, it) }
                    .onFailure { toast("Couldn't download this file") }
            }
        }
    }

    private fun handleMessage(tab: Tab, json: String) {
        val msg = runCatching { JSONObject(json) }.getOrNull() ?: return
        val action = msg.optString("action")
        val token = msg.optString("token", "")
        if (token.isNotEmpty()) {
            // Error page buttons (only accepted from our own error page)
            if (token != tab.errorToken) return
            val failed = tab.failedUrl ?: return
            val host = Uri.parse(failed).host ?: ""
            when (action) {
                "retry" -> tab.webView.loadUrl(failed)
                "search" -> tab.webView.loadUrl(Web.googleSearch(host))
                "privatedns" -> openPrivateDns()
                "isdown" -> tab.webView.loadUrl("https://downforeveryoneorjustme.com/$host")
            }
            return
        }
        if (!Web.isHome(tab.webView.url)) return   // home page actions only from the home page
        when (action) {
            "ready" -> pushHome(tab)
            "remove" -> { history.hidden = history.hidden + msg.optString("host"); pushHome(tab) }
            "restore" -> { history.hidden = emptySet(); pushHome(tab) }
            "settings" -> when (msg.optString("tab")) {
                "privacy" -> showClearData()
                "dns" -> showDnsHelp()
                "downloads" -> openDownloads()
                else -> showHistory()
            }
        }
    }

    // -----------------------------------------------------------------------------------------
    // Page loading and error recovery
    // -----------------------------------------------------------------------------------------

    inner class TabClient(private val tab: Tab) : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val uri = request.url
            when (uri.scheme?.lowercase()) {
                "http", "https", "about", "file", "data", "javascript", "blob" -> return false
                "intent" -> {
                    try {
                        val intent = Intent.parseUri(uri.toString(), Intent.URI_INTENT_SCHEME)
                        try { startActivity(intent) } catch (_: ActivityNotFoundException) {
                            intent.getStringExtra("browser_fallback_url")?.let { view.loadUrl(it) }
                        }
                    } catch (_: Exception) {
                    }
                    return true
                }
                else -> {
                    // mailto:, tel:, whatsapp:, market: … open in the right app
                    try { startActivity(Intent(Intent.ACTION_VIEW, uri)) } catch (_: ActivityNotFoundException) {
                        toast("No app can open this link")
                    }
                    return true
                }
            }
        }

        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
            if (!url.startsWith("about:") && !url.startsWith("data:")) tab.errorToken = null
            tab.loading = true
            if (tab === current) updateChrome()
        }

        override fun onPageFinished(view: WebView, url: String) {
            if (tab.errorToken == null && (url.startsWith("http://") || url.startsWith("https://"))) {
                tab.retries = 0
                history.record(url, view.title ?: "")
            }
            tab.loading = false
            pushHome(tab)
            if (tab === current) updateChrome()
        }

        override fun doUpdateVisitedHistory(view: WebView, url: String, isReload: Boolean) {
            if (tab === current) updateChrome()
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            if (request.isForMainFrame) handleError(tab, request.url.toString(), error.errorCode, error.description.toString())
        }

        @SuppressLint("WebViewClientOnReceivedSslError")
        override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: android.net.http.SslError) {
            handler.cancel()
            tab.failedUrl = error.url
            showError(tab, "other", Uri.parse(error.url).host ?: "",
                "This site's security certificate isn't valid, so LiteBrowser didn't open it. Your connection may be intercepted.")
        }
    }

    private fun handleError(tab: Tab, url: String, code: Int, description: String) {
        val host = Uri.parse(url).host
        if (host == null) { tab.failedUrl = url; showError(tab, "other", "", description); return }
        val isDns = code == WebViewClient.ERROR_HOST_LOOKUP
        val isNet = code == WebViewClient.ERROR_CONNECT || code == WebViewClient.ERROR_TIMEOUT

        // 1) Quiet retries for short glitches (not for timeouts, which already waited)
        if ((isDns || code == WebViewClient.ERROR_CONNECT) && tab.retries < 2) {
            tab.retries++
            main.postDelayed({ if (tab.webView.url == url || tab.errorToken == null) tab.webView.loadUrl(url) }, 800L * tab.retries)
            return
        }
        tab.retries = 0
        tab.failedUrl = url

        when {
            !isOnline() -> showError(tab, "offline", host, "")
            isDns -> thread {
                val r = Net.publicLookup(host)
                main.post {
                    if (tab.failedUrl == url) showError(tab, when (r) { "resolved" -> "dns"; "nx" -> "nosite"; else -> "offline" }, host, "")
                }
            }
            isNet -> {
                showError(tab, "checking", host, "")
                thread {
                    val d = Net.diagnose(host)
                    main.post {
                        if (tab.failedUrl != url) return@post
                        if (d.startsWith("blocked:")) showError(tab, "blocked", host, d.removePrefix("blocked:"))
                        else showError(tab, d, host, "")
                    }
                }
            }
            else -> showError(tab, "other", host, description)
        }
    }

    private fun showError(tab: Tab, kind: String, host: String, detail: String) {
        val token = UUID.randomUUID().toString()
        tab.errorToken = token
        tab.webView.loadDataWithBaseURL(null, ErrorPage.html(kind, host, detail, token), "text/html", "utf-8", null)
        if (kind == "offline") pollUntilOnline(tab, token)
        if (tab === current) updateChrome()
    }

    private fun pollUntilOnline(tab: Tab, token: String) {
        main.postDelayed({
            if (tab.errorToken != token) return@postDelayed
            if (isOnline()) tab.failedUrl?.let { tab.webView.loadUrl(it) } else pollUntilOnline(tab, token)
        }, 4000)
    }

    private fun isOnline(): Boolean {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    // -----------------------------------------------------------------------------------------
    // Popups, fullscreen video, file uploads
    // -----------------------------------------------------------------------------------------

    inner class TabChrome(private val tab: Tab) : WebChromeClient() {
        override fun onProgressChanged(view: WebView, newProgress: Int) {
            // no loading bar: the address bar and tab title update when the page is ready
        }

        override fun onReceivedTitle(view: WebView, title: String?) {
            if (tab === current) updateChrome()
        }

        override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean {
            newTab(null, activate = true, popup = resultMsg)
            return true
        }

        override fun onCloseWindow(window: WebView) = closeTab(tab)

        override fun onShowFileChooser(view: WebView, callback: ValueCallback<Array<Uri>>, params: FileChooserParams): Boolean {
            fileCallback?.onReceiveValue(null)
            fileCallback = callback
            return try {
                @Suppress("DEPRECATION")
                startActivityForResult(params.createIntent(), REQUEST_FILE)
                true
            } catch (_: Exception) {
                fileCallback = null
                false
            }
        }

        override fun onShowCustomView(view: View, callback: CustomViewCallback) {
            if (customView != null) { callback.onCustomViewHidden(); return }
            customView = view
            customCallback = callback
            (window.decorView as FrameLayout).addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            setFullscreen(true)
        }

        override fun onHideCustomView() = exitCustomView()
    }

    private fun exitCustomView() {
        customView?.let { (window.decorView as FrameLayout).removeView(it) }
        customView = null
        customCallback?.onCustomViewHidden()
        customCallback = null
        setFullscreen(false)
    }

    private fun setFullscreen(on: Boolean) {
        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.let {
                if (on) {
                    it.hide(WindowInsets.Type.systemBars())
                    it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                } else it.show(WindowInsets.Type.systemBars())
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = if (on)
                View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            else if (!night) View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR else 0
        }
    }

    @Deprecated("Uses the platform file chooser result")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_FILE) {
            fileCallback?.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(resultCode, data))
            fileCallback = null
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    // -----------------------------------------------------------------------------------------
    // Downloads
    // -----------------------------------------------------------------------------------------

    private fun download(tab: Tab, url: String, userAgent: String, disposition: String?, mime: String?) {
        var name = URLUtil.guessFileName(url, disposition, mime)
        if (url.startsWith("blob:") || url.startsWith("data:")) {
            // Files made by the page itself (converters, "export" buttons): read them from the page.
            val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime ?: "")
            if (name.endsWith(".bin") && ext != null) name = name.removeSuffix(".bin") + ".$ext"
            tab.pendingBlob = name.replace("/", "_")
            val js = """
                (async () => {
                  try {
                    const b = await (await fetch(${JSONObject.quote(url)})).blob();
                    const r = new FileReader();
                    r.onload = () => LiteAndroid.saveFile(b.type || ${JSONObject.quote(mime ?: "")}, String(r.result).split(',')[1] || '');
                    r.onerror = () => LiteAndroid.saveFile('', '');
                    r.readAsDataURL(b);
                  } catch (e) { LiteAndroid.saveFile('', ''); }
                })();
            """.trimIndent()
            tab.webView.evaluateJavascript(js, null)
            return
        }
        if (Build.VERSION.SDK_INT < 29 &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            pendingDownload = { download(tab, url, userAgent, disposition, mime) }
            requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), REQUEST_STORAGE)
            return
        }
        try {
            val req = DownloadManager.Request(Uri.parse(url)).apply {
                setMimeType(mime)
                CookieManager.getInstance().getCookie(url)?.let { addRequestHeader("Cookie", it) }
                addRequestHeader("User-Agent", userAgent)
                tab.webView.url?.let { addRequestHeader("Referer", it) }
                setTitle(name)
                setDescription("LiteBrowser")
                setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, name)
            }
            (getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager).enqueue(req)
            toast("Downloading $name. See your notifications.")
        } catch (e: Exception) {
            toast("Couldn't download: ${e.message}")
        }
    }

    private var pendingDownload: (() -> Unit)? = null

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_STORAGE) return
        val run = pendingDownload
        pendingDownload = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) run?.invoke()
        else toast("LiteBrowser needs storage access to save downloads")
    }

    /** Saves bytes into the phone's Downloads folder. */
    private fun saveBytes(name: String, mime: String, bytes: ByteArray) {
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, name)
                    put(MediaStore.Downloads.MIME_TYPE, mime)
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: throw IllegalStateException("storage unavailable")
                contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
            } else {
                @Suppress("DEPRECATION")
                val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                dir.mkdirs()
                File(dir, name).writeBytes(bytes)
            }
            toast("Saved $name to Downloads")
        } catch (e: Exception) {
            toast("Couldn't save $name: ${e.message}")
        }
    }

    // -----------------------------------------------------------------------------------------
    // Menus and dialogs
    // -----------------------------------------------------------------------------------------

    private fun showHistory() = showHistoryPage(false)

    private fun showClearData() {
        val labels = arrayOf("Browsing history", "Search history", "Cookies and sign-ins", "Cached images and files")
        val checked = booleanArrayOf(true, true, false, true)
        AlertDialog.Builder(this)
            .setTitle("Clear browsing data")
            .setMultiChoiceItems(labels, checked) { _, i, on -> checked[i] = on }
            .setPositiveButton("Clear") { _, _ ->
                if (checked[0]) { history.clearHistory(); tabs.forEach { it.webView.clearHistory() } }
                if (checked[1]) history.clearSearches()
                if (checked[2]) {
                    CookieManager.getInstance().removeAllCookies(null)
                    CookieManager.getInstance().flush()
                    WebStorage.getInstance().deleteAllData()
                }
                if (checked[3]) tabs.forEach { it.webView.clearCache(true) }
                current?.let { pushHome(it) }
                toast("Cleared")
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun showDnsHelp() {
        AlertDialog.Builder(this)
            .setTitle("DNS")
            .setMessage(
                "Android apps can't change DNS themselves, but Android has it built in, and it's encrypted:\n\n" +
                "Settings → Network & internet → Private DNS → \"Private DNS provider hostname\", then enter one of:\n\n" +
                "•  dns.google  (Google)\n" +
                "•  one.one.one.one  (Cloudflare)\n" +
                "•  dns.adguard-dns.com  (blocks ads)\n" +
                "•  your own server, e.g. love.dns.zeshanhaider.dev\n\n" +
                "LiteBrowser still checks every failed page and tells you whether DNS, your network or the site is the problem."
            )
            .setPositiveButton("Open settings") { _, _ -> openPrivateDns() }
            .setNegativeButton("Close", null)
            .show()
    }

    private fun openPrivateDns() {
        val attempts = listOf(
            Intent("android.settings.PRIVATE_DNS_SETTINGS"),
            Intent(Settings.ACTION_WIRELESS_SETTINGS),
            Intent(Settings.ACTION_SETTINGS),
        )
        for (i in attempts) {
            try { startActivity(i); toast("Open “Private DNS”"); return } catch (_: Exception) { }
        }
    }

    private fun toggleDesktop() {
        desktopMode = !desktopMode
        tabs.forEach { it.webView.settings.userAgentString = if (desktopMode) DESKTOP_UA else null }
        current?.webView?.reload()
        toast(if (desktopMode) "Desktop site on" else "Desktop site off")
    }

    private fun sharePage() {
        val url = current?.shownUrl?.takeIf { it.startsWith("http") } ?: return
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, url)
        }, "Share page"))
    }

    private fun showAbout() {
        AlertDialog.Builder(this)
            .setTitle("LiteBrowser $currentVersion")
            .setMessage("A small, fast browser with Google search, top sites, PIN lock and smart DNS error checks.\n\nYour history stays on this phone.")
            .setPositiveButton("Check for updates") { _, _ -> checkForUpdate(manual = true) }
            .setNegativeButton("Close", null)
            .show()
    }

    private fun openDownloads() {
        try { startActivity(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS)) }
        catch (_: Exception) { toast("Open the Files app → Downloads") }
    }

    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_SHORT).show()

    // -----------------------------------------------------------------------------------------
    // Back button and lifecycle
    // -----------------------------------------------------------------------------------------

    @Deprecated("Handles back for web history and tabs")
    override fun onBackPressed() {
        when {
            lockView != null -> moveTaskToBack(true)
            customView != null -> exitCustomView()
            closeTopOverlay() -> {}
            findBar.visibility == View.VISIBLE -> hideFind()
            address.hasFocus() -> { address.clearFocus(); current?.webView?.requestFocus() }
            current?.webView?.canGoBack() == true -> current?.webView?.goBack()
            tabs.size > 1 -> current?.let { closeTab(it) }
            else -> @Suppress("DEPRECATION") super.onBackPressed()
        }
    }

    override fun onPause() {
        super.onPause()
        CookieManager.getInstance().flush()
    }

    override fun onDestroy() {
        tabs.forEach { it.webView.destroy() }
        super.onDestroy()
    }

    companion object {
        private const val REQUEST_FILE = 42
        private const val REQUEST_STORAGE = 43
        private const val DESKTOP_UA =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    }
}
