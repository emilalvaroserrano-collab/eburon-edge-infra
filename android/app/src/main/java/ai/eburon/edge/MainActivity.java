package ai.eburon.edge;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.view.View;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.PermissionRequest;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

public class MainActivity extends Activity {
    private static final String HOME = "http://127.0.0.1:8850/";
    private static final int MIC_REQUEST = 7001;
    private WebView web;
    private PermissionRequest pendingMic;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        web = new WebView(this);
        web.setBackgroundColor(Color.rgb(6,7,8));
        setContentView(web);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        WebView.setWebContentsDebuggingEnabled(false);
        web.addJavascriptInterface(new NativeBridge(), "EburonNative");
        web.setWebChromeClient(new WebChromeClient() {
            @Override public void onPermissionRequest(PermissionRequest request) {
                runOnUiThread(() -> {
                    boolean audio = false;
                    for (String r : request.getResources()) if (PermissionRequest.RESOURCE_AUDIO_CAPTURE.equals(r)) audio = true;
                    if (!audio) { request.deny(); return; }
                    if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) request.grant(new String[]{PermissionRequest.RESOURCE_AUDIO_CAPTURE});
                    else { pendingMic = request; requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, MIC_REQUEST); }
                });
            }
        });
        web.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri u=request.getUrl();
                if (("127.0.0.1".equals(u.getHost()) || "localhost".equals(u.getHost())) && "http".equals(u.getScheme())) return false;
                startActivity(new Intent(Intent.ACTION_VIEW,u)); return true;
            }
            @Override public void onReceivedError(WebView view, WebResourceRequest req, WebResourceError err) {
                if (req.isForMainFrame()) showOffline();
            }
        });
        if (state == null) web.loadUrl(HOME); else web.restoreState(state);
    }

    @Override public void onSaveInstanceState(Bundle out) { web.saveState(out); super.onSaveInstanceState(out); }
    @Override public void onBackPressed() { if (web.canGoBack()) web.goBack(); else super.onBackPressed(); }
    @Override public void onRequestPermissionsResult(int code,String[] perms,int[] grants) {
        super.onRequestPermissionsResult(code,perms,grants);
        if (code==MIC_REQUEST && pendingMic!=null) {
            if (grants.length>0 && grants[0]==PackageManager.PERMISSION_GRANTED) pendingMic.grant(new String[]{PermissionRequest.RESOURCE_AUDIO_CAPTURE}); else pendingMic.deny();
            pendingMic=null;
        }
    }

    private void showOffline() {
        String html="<html><meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0;background:#060708;color:white;font-family:system-ui;display:grid;place-items:center;min-height:100vh}.c{width:min(88vw,520px);background:#101214;border:1px solid #272a2f;border-radius:24px;padding:28px}h1{margin:8px 0 12px}p{color:#a7adb5;line-height:1.55}button{width:100%;padding:15px;margin-top:10px;border:0;border-radius:14px;font-size:16px;font-weight:700}.secondary{background:#1b1e22;color:white}</style><body><div class='c'><small>EBURON EDGE</small><h1>Local engine is offline</h1><p>Start the Eburon Edge stack in Termux. The app connects only to <b>127.0.0.1:8850</b>.</p><button onclick=\"location.href='"+HOME+"'\">Retry</button><button class='secondary' onclick='EburonNative.openTermux()'>Open Termux</button></div></body></html>";
        web.loadDataWithBaseURL(HOME,html,"text/html","UTF-8",null);
    }

    private class NativeBridge {
        @JavascriptInterface public void openTermux() {
            runOnUiThread(() -> {
                Intent i=getPackageManager().getLaunchIntentForPackage("com.termux");
                if(i!=null) startActivity(i); else startActivity(new Intent(Intent.ACTION_VIEW,Uri.parse("https://f-droid.org/packages/com.termux/")));
            });
        }
    }
}
