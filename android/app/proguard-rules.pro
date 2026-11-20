# Keep methods that JavaScript calls through the WebView bridge.
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
