package cz.inloop.kds

import android.annotation.SuppressLint
import android.os.Bundle
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
    private var pendingPayload: String = ""

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // 1. Inicializace hardwarového klíče v TEE
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

        executor = ContextCompat.getMainExecutor(this)

        // 3. Kiosk mód
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemUI()

        // 4. Konfigurace WebView
        webView = WebView(this)
        setContentView(webView)

        val settings = webView.settings
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.databaseEnabled = true
        settings.allowFileAccess = true
        settings.allowContentAccess = true
        settings.cacheMode = WebSettings.LOAD_NO_CACHE

        // Registrace JavaScript rozhraní
        webView.addJavascriptInterface(WebAppInterface(), "AndroidBridge")

        webView.webViewClient = object : WebViewClient() {
            override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
                view?.postDelayed({ view.reload() }, 1500)
            }
        }

        webView.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest?) {
                request?.grant(request.resources)
            }
            override fun onConsoleMessage(consoleMessage: ConsoleMessage?): Boolean {
                return super.onConsoleMessage(consoleMessage)
            }
        }

        webView.loadUrl("http://127.0.0.1:$port")
    }

    private fun showBiometricDialog(signature: Signature, payload: String) {
        val biometricManager = BiometricManager.from(this)
        val canAuth = biometricManager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)

        if (canAuth != BiometricManager.BIOMETRIC_SUCCESS) {
            val errorReason = when (canAuth) {
                BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> "Zařízení nemá biometrický hardware."
                BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> "Biometrický senzor je momentálně nedostupný."
                BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "V zařízení není zaregistrován žádný otisk prstu! Přidejte otisk v nastavení Androidu."
                else -> "Biometrie není k dispozici (kód $canAuth)."
            }
            notifyBiometricError(errorReason)
            return
        }

        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Autorizace várky šéfkuchařem")
            .setSubtitle("Přiložte prst k hardwarovému senzoru pro pečeť do TEE")
            .setNegativeButtonText("Zrušit")
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .build()

        val biometricPrompt = BiometricPrompt(this, executor, object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                super.onAuthenticationSucceeded(result)
                val authedSignature = result.cryptoObject?.signature
                if (authedSignature != null) {
                    try {
                        val signatureBase64 = CryptoManager.signData(authedSignature, payload.toByteArray(Charsets.UTF_8))
                        val publicKey = CryptoManager.getPublicKeyBase64()

                        val safeSig = JSONObject.quote(signatureBase64)
                        val safeKey = JSONObject.quote(publicKey)
                        webView.post {
                            webView.evaluateJavascript("window.onBiometricSuccess($safeSig, $safeKey);", null)
                        }
                    } catch (e: Exception) {
                        notifyBiometricError("Chyba podpisu v TEE: ${e.message}")
                    }
                } else {
                    notifyBiometricError("Chyba: Podpisový objekt nebyl odemčen.")
                }
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                super.onAuthenticationError(errorCode, errString)
                notifyBiometricError(errString.toString())
            }

            override fun onAuthenticationFailed() {
                super.onAuthenticationFailed()
            }
        })

        try {
            biometricPrompt.authenticate(promptInfo, BiometricPrompt.CryptoObject(signature))
        } catch (e: Exception) {
            notifyBiometricError("Chyba spuštění biometrie: ${e.message}")
        }
    }

    private fun notifyBiometricError(msg: String) {
        val safeMsg = JSONObject.quote(msg)
        webView.post {
            webView.evaluateJavascript("window.onBiometricError($safeMsg);", null)
        }
    }

    inner class WebAppInterface {
        @JavascriptInterface
        fun authenticateAndSign(payloadJson: String) {
            runOnUiThread {
                pendingPayload = payloadJson
                val sigObject = CryptoManager.getSignatureObject()

                if (sigObject != null) {
                    showBiometricDialog(sigObject, pendingPayload)
                } else {
                    notifyBiometricError("Hardwarový TEE klíč nebyl připraven. Ujistěte se, že máte v Androidu nastaven otisk prstu.")
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
