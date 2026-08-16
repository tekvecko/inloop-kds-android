package cz.inloop.kds

import android.annotation.SuppressLint
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.WindowManager
import android.webkit.*
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.security.Signature
import java.util.concurrent.Executor

class MainActivity : AppCompatActivity() {

    private lateinit var webView: WebView
    private var server: KdsEmbeddedServer? = null
    private val port = 5005
    private lateinit var executor: Executor

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        executor = ContextCompat.getMainExecutor(this)

        // 1. Inicializace TEE klíče
        try {
            CryptoManager.initHardwareKey()
        } catch (e: Exception) {
            e.printStackTrace()
        }

        // 2. Start vestavěného serveru
        try {
            server = KdsEmbeddedServer(port, applicationContext)
            server?.start()
        } catch (e: Exception) {
            e.printStackTrace()
        }

        // 3. Kiosk / Fullscreen nastavení s podporou rotace
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemUI()

        // 4. WebView konfigurace s optimálním viewport scalingem
        webView = WebView(this)
        setContentView(webView)

        val settings = webView.settings
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.databaseEnabled = true
        settings.allowFileAccess = true
        settings.allowContentAccess = true
        settings.useWideViewPort = true
        settings.loadWithOverviewMode = true
        settings.cacheMode = WebSettings.LOAD_NO_CACHE

        // Registrace JavaScript Interface
        webView.addJavascriptInterface(WebAppInterface(), "AndroidBridge")

        webView.webViewClient = object : WebViewClient() {
            override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
                view?.postDelayed({ view.reload() }, 1500)
            }
        }

        webView.webChromeClient = object : WebChromeClient() {
            override fun onJsAlert(view: WebView?, url: String?, message: String?, result: JsResult?): Boolean {
                Toast.makeText(this@MainActivity, message, Toast.LENGTH_LONG).show()
                result?.confirm()
                return true
            }
        }

        webView.loadUrl("http://127.0.0.1:$port")
    }

    private fun showBiometricPrompt(signature: Signature, payload: String) {
        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Autorizace výdeje (InLoop TEE)")
            .setSubtitle("Přiložte prst k hardwarovému senzoru pro pečeť várky")
            .setNegativeButtonText("Zrušit")
            .build()

        val biometricPrompt = BiometricPrompt(this, executor, object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                super.onAuthenticationSucceeded(result)
                val authedSig = result.cryptoObject?.signature
                if (authedSig != null) {
                    try {
                        val signatureBase64 = CryptoManager.signData(authedSig, payload.toByteArray(Charsets.UTF_8))
                        val publicKey = CryptoManager.getPublicKeyBase64()

                        val safeSig = JSONObject.quote(signatureBase64)
                        val safeKey = JSONObject.quote(publicKey)

                        Handler(Looper.getMainLooper()).post {
                            webView.evaluateJavascript("window.onBiometricSuccess($safeSig, $safeKey);", null)
                        }
                    } catch (e: Exception) {
                        handleError("Chyba při podepisování v TEE: ${e.message}")
                    }
                } else {
                    handleError("Podpisový objekt nebyl odemčen.")
                }
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                super.onAuthenticationError(errorCode, errString)
                handleError("Biometrie zrušena/chyba ($errorCode): $errString")
            }

            override fun onAuthenticationFailed() {
                super.onAuthenticationFailed()
                Toast.makeText(this@MainActivity, "Otisk nerozpoznán, zkuste to znovu", Toast.LENGTH_SHORT).show()
            }
        })

        try {
            biometricPrompt.authenticate(promptInfo, BiometricPrompt.CryptoObject(signature))
        } catch (e: Exception) {
            handleError("Spuštění senzoru selhalo: ${e.message}")
        }
    }

    private fun handleError(msg: String) {
        Handler(Looper.getMainLooper()).post {
            Toast.makeText(this@MainActivity, msg, Toast.LENGTH_LONG).show()
            val safeMsg = JSONObject.quote(msg)
            webView.evaluateJavascript("window.onBiometricError($safeMsg);", null)
        }
    }

    inner class WebAppInterface {
        @JavascriptInterface
        fun authenticateAndSign(payloadJson: String) {
            Handler(Looper.getMainLooper()).post {
                val biometricManager = BiometricManager.from(this@MainActivity)
                val canAuth = biometricManager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.BIOMETRIC_WEAK)

                if (canAuth != BiometricManager.BIOMETRIC_SUCCESS) {
                    handleError("V zařízení není nastaven otisk prstu nebo je senzor nedostupný (kód $canAuth). Nastavte otisk prstu v nastavení Androidu.")
                    return@post
                }

                val sigObject = CryptoManager.getSignatureObject()
                if (sigObject != null) {
                    showBiometricPrompt(sigObject, payloadJson)
                } else {
                    handleError("Nelze inicializovat TEE klíč. Zkontrolujte zámek obrazovky.")
                }
            }
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUI()
    }

    private fun hideSystemUI() {
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_FULLSCREEN
        )
    }

    override fun onDestroy() {
        super.onDestroy()
        server?.stop()
    }
}
