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
import android.graphics.Bitmap
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

    private lateinit var root: LinearLayout
    private lateinit var address: EditText
    private lateinit var backBtn: TextView
    private lateinit var forwardBtn: TextView
    private lateinit var tabsBtn: TextView
    private lateinit var progress: ProgressBar
    private lateinit var container: FrameLayout

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

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    // -----------------------------------------------------------------------------------------
    // Setup
    // -----------------------------------------------------------------------------------------

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        history = HistoryStore(this)
        buildUi()
        val start = urlFromIntent(intent) ?: Web.HOME
        newTab(start)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        urlFromIntent(intent)?.let { newTab(it) }
    }

    private fun urlFromIntent(i: Intent?): String? {
        if (i == null) return null
        if (i.action == Intent.ACTION_WEB_SEARCH) i.getStringExtra("query")?.let { return Web.resolveInput(it) }
        return i.dataString
    }

    private fun buildUi() {
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(barColor)
        }

        // Toolbar: back, forward, address bar, tabs, menu
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), dp(6), dp(4), dp(6))
        }
        backBtn = iconButton("‹", 30f) { current?.webView?.takeIf { it.canGoBack() }?.goBack() }
        forwardBtn = iconButton("›", 30f) { current?.webView?.takeIf { it.canGoForward() }?.goForward() }
        address = EditText(this).apply {
            hint = "Search Google or type a URL"
            setSingleLine(true)
            textSize = 15f
            setTextColor(textColor)
            setHintTextColor(mutedColor)
            imeOptions = EditorInfo.IME_ACTION_GO
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_URI
            setSelectAllOnFocus(true)
            background = GradientDrawable().apply { cornerRadius = dp(22).toFloat(); setColor(fieldColor) }
            setPadding(dp(16), dp(9), dp(16), dp(9))
            setOnEditorActionListener { _, actionId, event ->
                val go = actionId == EditorInfo.IME_ACTION_GO ||
                    (event != null && event.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_DOWN)
                if (go) { submitAddress(); true } else false
            }
            setOnFocusChangeListener { _, focused ->
                if (focused) { setText(current?.shownUrl?.takeUnless { Web.isHome(it) } ?: ""); selectAll() }
                else updateChrome()
            }
        }
        tabsBtn = TextView(this).apply {
            gravity = Gravity.CENTER
            textSize = 12f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(textColor)
            background = GradientDrawable().apply { cornerRadius = dp(5).toFloat(); setStroke(dp(2), textColor) }
            setOnClickListener { showTabs() }
        }
        val tabsFrame = FrameLayout(this).apply {
            addView(tabsBtn, FrameLayout.LayoutParams(dp(24), dp(24), Gravity.CENTER))
            setOnClickListener { showTabs() }
        }
        val menuBtn = iconButton("⋮", 24f) { showMenu(it) }

        bar.addView(backBtn, LinearLayout.LayoutParams(dp(40), dp(44)))
        bar.addView(forwardBtn, LinearLayout.LayoutParams(dp(40), dp(44)))
        bar.addView(address, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        bar.addView(tabsFrame, LinearLayout.LayoutParams(dp(46), dp(44)))
        bar.addView(menuBtn, LinearLayout.LayoutParams(dp(40), dp(44)))

        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            visibility = View.GONE          // no loading bar at the top
        }
        container = FrameLayout(this)

        root.addView(bar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        root.addView(container, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)
        applySystemBars()
    }

    private fun iconButton(glyph: String, size: Float, onClick: (View) -> Unit) = TextView(this).apply {
        text = glyph
        textSize = size
        gravity = Gravity.CENTER
        setTextColor(textColor)
        val tv = TypedValue()
        context.theme.resolveAttribute(android.R.attr.selectableItemBackgroundBorderless, tv, true)
        setBackgroundResource(tv.resourceId)
        setOnClickListener { onClick(it) }
    }

    /** Edge-to-edge on Android 15+: keep the toolbar below the status bar and above the keyboard. */
    private fun applySystemBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            root.setOnApplyWindowInsetsListener { v, insets ->
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
        CookieManager.getInstance().setAcceptThirdPartyCookies(wv, true)
        wv.addJavascriptInterface(Bridge(tab), "LiteAndroid")
        wv.webViewClient = TabClient(tab)
        wv.webChromeClient = TabChrome(tab)
        wv.setDownloadListener { dlUrl, ua, disposition, mime, _ -> download(tab, dlUrl, ua, disposition, mime) }

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

    private fun showTabs() {
        val titles = tabs.map { (if (it === current) "●  " else "     ") + it.title }.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle("${tabs.size} tab${if (tabs.size == 1) "" else "s"}")
            .setItems(titles) { _, which -> switchTo(tabs[which]) }
            .setPositiveButton("New tab") { _, _ -> newTab(Web.HOME); focusAddress() }
            .setNeutralButton("Close this tab") { _, _ -> current?.let { closeTab(it) } }
            .setNegativeButton("Close all") { _, _ ->
                tabs.toList().forEach { container.removeView(it.webView); it.webView.destroy() }
                tabs.clear(); current = null
                newTab(Web.HOME)
            }
            .show()
    }

    // -----------------------------------------------------------------------------------------
    // Toolbar
    // -----------------------------------------------------------------------------------------

    private fun submitAddress() {
        val tab = current ?: return
        tab.webView.loadUrl(Web.resolveInput(address.text.toString()))
        address.clearFocus()
        (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(address.windowToken, 0)
        tab.webView.requestFocus()
    }

    private fun focusAddress() {
        address.requestFocus()
        main.postDelayed({
            (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(address, InputMethodManager.SHOW_IMPLICIT)
        }, 150)
    }

    private fun updateChrome() {
        val tab = current ?: return
        if (!address.hasFocus()) address.setText(Web.pretty(tab.shownUrl))
        backBtn.alpha = if (tab.webView.canGoBack()) 1f else 0.3f
        forwardBtn.alpha = if (tab.webView.canGoForward()) 1f else 0.3f
        tabsBtn.text = if (tabs.size > 99) ":)" else tabs.size.toString()
    }

    private fun showMenu(anchor: View) {
        val m = PopupMenu(this, anchor)
        m.menu.add(0, 1, 0, "New tab")
        m.menu.add(0, 2, 1, "Reload")
        m.menu.add(0, 3, 2, "History")
        m.menu.add(0, 4, 3, "Search history")
        m.menu.add(0, 10, 3, "Downloads")
        m.menu.add(0, 5, 4, "Clear browsing data")
        m.menu.add(0, 6, 5, "Desktop site").apply { isCheckable = true; isChecked = desktopMode }
        m.menu.add(0, 7, 6, "Share page")
        m.menu.add(0, 8, 7, "DNS settings")
        m.menu.add(0, 9, 8, "About LiteBrowser")
        m.setOnMenuItemClickListener { item ->
            when (item.itemId) {
                1 -> { newTab(Web.HOME); focusAddress() }
                2 -> current?.let { t -> if (t.errorToken != null) t.failedUrl?.let { t.webView.loadUrl(it) } else t.webView.reload() }
                3 -> showHistory()
                4 -> showSearches()
                5 -> showClearData()
                6 -> toggleDesktop()
                7 -> sharePage()
                8 -> showDnsHelp()
                9 -> showAbout()
                10 -> openDownloads()
            }
            true
        }
        m.show()
    }

    // -----------------------------------------------------------------------------------------
    // Home page
    // -----------------------------------------------------------------------------------------

    private fun pushHome(tab: Tab) {
        if (!Web.isHome(tab.webView.url)) return
        val state = JSONObject()
            .put("sites", history.topSites(8))
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
            if (tab === current) updateChrome()
        }

        override fun onPageFinished(view: WebView, url: String) {
            if (tab.errorToken == null && (url.startsWith("http://") || url.startsWith("https://"))) {
                tab.retries = 0
                history.record(url, view.title ?: "")
            }
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

    private fun showHistory() {
        val items = history.items.take(300)
        if (items.isEmpty()) { toast("No history yet"); return }
        val labels = items.map { (it.title.ifBlank { Uri.parse(it.url).host ?: it.url }) + "\n" + Web.pretty(it.url) }.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle("History")
            .setItems(labels) { _, i -> current?.webView?.loadUrl(items[i].url) }
            .setNeutralButton("Clear history") { _, _ -> history.clearHistory(); tabs.forEach { it.webView.clearHistory() }; toast("History cleared") }
            .setNegativeButton("Close", null)
            .show()
    }

    private fun showSearches() {
        val items = history.searches.take(300)
        if (items.isEmpty()) { toast("No searches yet"); return }
        AlertDialog.Builder(this)
            .setTitle("Search history")
            .setItems(items.map { "🔍  " + it.query }.toTypedArray()) { _, i -> current?.webView?.loadUrl(Web.googleSearch(items[i].query)) }
            .setNeutralButton("Clear searches") { _, _ -> history.clearSearches(); toast("Search history cleared") }
            .setNegativeButton("Close", null)
            .show()
    }

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
        val version = runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull() ?: ""
        AlertDialog.Builder(this)
            .setTitle("LiteBrowser $version")
            .setMessage("A small, fast browser with Google search, top sites and smart DNS error checks.\n\nYour history stays on this phone.")
            .setPositiveButton("OK", null)
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
            customView != null -> exitCustomView()
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
