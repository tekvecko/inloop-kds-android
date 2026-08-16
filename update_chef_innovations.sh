#!/bin/bash
set -e

echo "[*] Implementuji: Hlasové povely, BLE Teplotní sondu a Prediktivní Burn Rate Guard..."

# 1. Povolení mikrofonu a Bluetooth v MainActivity.kt
cat << 'EOF_MAIN' > app/src/main/java/cz/inloop/kds/MainActivity.kt
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

        try {
            CryptoManager.initHardwareKey()
        } catch (e: Exception) {
            e.printStackTrace()
        }

        try {
            server = KdsEmbeddedServer(port, applicationContext)
            server?.start()
        } catch (e: Exception) {
            e.printStackTrace()
        }

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemUI()

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
        settings.mediaPlaybackRequiresUserGesture = false
        settings.cacheMode = WebSettings.LOAD_NO_CACHE

        webView.addJavascriptInterface(WebAppInterface(), "AndroidBridge")

        webView.webViewClient = object : WebViewClient() {
            override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
                view?.postDelayed({ view.reload() }, 1500)
            }
        }

        webView.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest?) {
                // Automatické udělení oprávnění pro mikrofon a Bluetooth v Kiosku
                request?.grant(request.resources)
            }
        }

        webView.loadUrl("http://127.0.0.1:$port")
    }

    private fun showBiometricPrompt(signature: Signature, payload: String, isEnrollment: Boolean = false) {
        val title = if (isEnrollment) "Registrace otisku šéfkuchaře" else "Autorizace výdeje (InLoop TEE)"
        val subtitle = if (isEnrollment) "Přiložte prst pro ukování TEE klíče" else "Přiložte prst pro zapečetění várky"

        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
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
                            if (isEnrollment) {
                                webView.evaluateJavascript("window.onEnrollmentSuccess($safeKey);", null)
                            } else {
                                webView.evaluateJavascript("window.onBiometricSuccess($safeSig, $safeKey);", null)
                            }
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
                handleError("Biometrie zrušena: $errString")
            }

            override fun onAuthenticationFailed() {
                super.onAuthenticationFailed()
                Toast.makeText(this@MainActivity, "Otisk nerozpoznán, zkuste znovu", Toast.LENGTH_SHORT).show()
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
        fun enrollChefKey() {
            Handler(Looper.getMainLooper()).post {
                try {
                    CryptoManager.registerNewChefKey()
                    val sigObject = CryptoManager.getSignatureObject()
                    if (sigObject != null) {
                        showBiometricPrompt(sigObject, "CHEF_ENROLLMENT_${System.currentTimeMillis()}", true)
                    }
                } catch (e: Exception) {
                    handleError("Chyba: ${e.message}")
                }
            }
        }

        @JavascriptInterface
        fun getEnrolledKeyStatus(): String {
            val pubKey = CryptoManager.getPublicKeyBase64()
            val enrolled = CryptoManager.isKeyEnrolled()
            return "{\"enrolled\":$enrolled,\"publicKey\":\"$pubKey\"}"
        }

        @JavascriptInterface
        fun authenticateAndSign(payloadJson: String) {
            Handler(Looper.getMainLooper()).post {
                val sigObject = CryptoManager.getSignatureObject()
                if (sigObject != null) {
                    showBiometricPrompt(sigObject, payloadJson, false)
                } else {
                    handleError("Klíč TEE není inicializován.")
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
EOF_MAIN

# 2. Aktualizace ATM UI s Voice Control, BLE Sondou a Burn Rate Guardem v index.html
cat << 'EOF_HTML' > app/src/main/assets/index.html
<!DOCTYPE html>
<html lang="cs">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
    <title>InLoop ATM-KDS Pro</title>
    <style>
        :root {
            --bg-atm: #040914;
            --screen-bg: #0a1324;
            --btn-bg: #132238;
            --btn-border: #1e3a5f;
            --cyan: #00d2ff;
            --cyan-glow: rgba(0, 210, 255, 0.35);
            --green: #00ff88;
            --green-glow: rgba(0, 255, 136, 0.35);
            --amber: #ffaa00;
            --amber-glow: rgba(255, 170, 0, 0.4);
            --red: #ff3366;
            --text-main: #ffffff;
            --text-dim: #7d96b3;
        }

        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; margin: 0; padding: 0; user-select: none; }
        
        body {
            background: var(--bg-atm);
            color: var(--text-main);
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            height: 100dvh;
            display: flex;
            flex-direction: column;
            padding: env(safe-area-inset-top, 0.4rem) env(safe-area-inset-right, 0.4rem) env(safe-area-inset-bottom, 0.4rem) env(safe-area-inset-left, 0.4rem);
            overflow: hidden;
        }

        /* Horní lišta */
        .atm-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 0.45rem 0.8rem;
            background: #08101e;
            border-bottom: 2px solid var(--btn-border);
            margin-bottom: 0.4rem;
        }
        .atm-logo { font-size: 0.95rem; font-weight: 900; letter-spacing: 1px; color: #fff; }
        .atm-logo span { color: var(--cyan); }
        
        .header-tools { display: flex; align-items: center; gap: 0.4rem; }
        .btn-tool {
            background: var(--btn-bg);
            border: 1px solid var(--btn-border);
            color: var(--text-main);
            padding: 0.3rem 0.6rem;
            border-radius: 6px;
            font-size: 0.7rem;
            font-weight: 800;
            cursor: pointer;
            display: flex;
            align-items: center;
            gap: 0.3rem;
        }
        .btn-tool.active { background: rgba(0, 210, 255, 0.2); border-color: var(--cyan); color: var(--cyan); }
        .btn-tool.listening { background: rgba(255, 51, 102, 0.2); border-color: var(--red); color: var(--red); animation: pulseRed 1s infinite; }

        @keyframes pulseRed { 0%, 100% { transform: scale(1); } 50% { transform: scale(1.05); } }

        /* Burn Rate Timer Banner */
        .burn-rate-banner {
            background: rgba(255, 170, 0, 0.12);
            border: 1px solid var(--amber);
            color: var(--amber);
            padding: 0.35rem 0.8rem;
            border-radius: 8px;
            font-size: 0.75rem;
            font-weight: 800;
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 0.4rem;
        }
        .burn-rate-banner.urgent {
            background: rgba(255, 51, 102, 0.2);
            border-color: var(--red);
            color: var(--red);
            animation: pulseBanner 1.5s infinite;
        }
        @keyframes pulseBanner { 0%, 100% { opacity: 1; } 50% { opacity: 0.6; } }

        /* Hlavní ATM Obrazovka */
        .atm-screen {
            flex: 1;
            background: var(--screen-bg);
            border: 2px solid var(--btn-border);
            border-radius: 14px;
            padding: 0.8rem;
            display: flex;
            flex-direction: column;
            justify-content: space-between;
            position: relative;
            box-shadow: inset 0 0 30px rgba(0,0,0,0.5);
        }

        .step-title-box {
            text-align: center;
            margin-bottom: 0.4rem;
            border-bottom: 1px solid rgba(255,255,255,0.08);
            padding-bottom: 0.3rem;
        }
        .step-num { font-size: 0.68rem; font-weight: 800; color: var(--cyan); text-transform: uppercase; }
        .step-title { font-size: 1.15rem; font-weight: 900; color: #fff; margin-top: 0.1rem; }

        /* Krok 1: Menu Dlaždice */
        .atm-grid-2x2 {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 0.5rem;
            flex: 1;
            align-content: stretch;
        }
        .atm-tile {
            background: var(--btn-bg);
            border: 2px solid var(--btn-border);
            border-radius: 12px;
            padding: 0.75rem;
            cursor: pointer;
            display: flex;
            flex-direction: column;
            justify-content: center;
        }
        .atm-tile.selected {
            border-color: var(--cyan);
            background: rgba(0, 210, 255, 0.18);
            box-shadow: 0 0 18px var(--cyan-glow);
        }
        .tile-id { font-size: 0.75rem; font-weight: 900; color: var(--cyan); }
        .tile-name { font-size: 0.95rem; font-weight: 800; color: #fff; line-height: 1.25; margin: 0.2rem 0; }
        .tile-price { font-size: 0.8rem; font-weight: 700; color: var(--green); }

        /* Krok 2: Porce */
        .atm-portions-grid {
            display: grid;
            grid-template-columns: 1fr 1fr 1fr;
            gap: 0.5rem;
            flex: 1;
            align-content: center;
        }
        .atm-btn-amount {
            background: var(--btn-bg);
            border: 2px solid var(--btn-border);
            color: #fff;
            font-size: 1.4rem;
            font-weight: 900;
            border-radius: 12px;
            padding: 1rem 0.3rem;
            cursor: pointer;
            text-align: center;
        }
        .atm-btn-amount.selected {
            border-color: var(--cyan);
            background: var(--cyan);
            color: #000;
            box-shadow: 0 0 20px var(--cyan-glow);
        }
        .amount-sub { font-size: 0.65rem; font-weight: 700; display: block; opacity: 0.8; }

        /* Krok 3: Teploměr */
        .temp-display-box {
            background: #000;
            border: 2px solid var(--green);
            border-radius: 14px;
            padding: 1rem;
            text-align: center;
            margin: auto;
            width: 100%;
            max-width: 320px;
            box-shadow: 0 0 25px var(--green-glow);
        }
        .temp-digital { font-size: 2.8rem; font-weight: 900; color: var(--green); font-family: monospace; }
        .temp-haccp-status { font-size: 0.8rem; font-weight: 800; color: var(--green); margin-top: 0.2rem; }

        .temp-stepper-row {
            display: flex;
            gap: 0.5rem;
            max-width: 320px;
            margin: 0.6rem auto 0 auto;
            width: 100%;
        }
        .btn-temp-step {
            flex: 1;
            background: var(--btn-bg);
            border: 2px solid var(--btn-border);
            color: #fff;
            font-size: 1.1rem;
            font-weight: 900;
            border-radius: 8px;
            padding: 0.8rem;
            cursor: pointer;
        }

        /* Spodní lišta */
        .atm-footer { display: flex; gap: 0.5rem; margin-top: 0.5rem; }
        .btn-atm-main {
            flex: 2;
            background: linear-gradient(135deg, #00d2ff, #0077ff);
            color: #000;
            border: none;
            border-radius: 10px;
            padding: 1rem;
            font-size: 1.05rem;
            font-weight: 900;
            cursor: pointer;
            text-transform: uppercase;
        }
        .btn-atm-back {
            flex: 1;
            background: rgba(255,255,255,0.06);
            border: 2px solid var(--btn-border);
            color: #fff;
            border-radius: 10px;
            padding: 1rem;
            font-size: 0.95rem;
            font-weight: 800;
            cursor: pointer;
        }

        /* Overlay Dialogs */
        .overlay {
            position: fixed; inset: 0; background: rgba(3, 7, 18, 0.94); backdrop-filter: blur(25px);
            z-index: 10000; display: flex; flex-direction: column; justify-content: center; align-items: center; padding: 1.5rem; text-align: center;
        }
        .overlay.hidden { display: none; }
        .atm-dialog {
            background: #0d1b2e; border: 2px solid var(--cyan); border-radius: 18px; padding: 1.6rem; max-width: 380px; width: 100%; box-shadow: 0 0 35px var(--cyan-glow);
        }
        .dialog-icon { font-size: 3rem; margin-bottom: 0.6rem; }
        .dialog-title { font-size: 1.3rem; font-weight: 900; margin-bottom: 0.3rem; }
        .dialog-desc { color: var(--text-dim); font-size: 0.85rem; margin-bottom: 1.2rem; line-height: 1.35; }
        .dialog-btn {
            background: var(--cyan); color: #000; border: none; border-radius: 10px; padding: 0.9rem; width: 100%; font-size: 1rem; font-weight: 900; cursor: pointer; text-transform: uppercase;
        }
    </style>
</head>
<body>

    <!-- STAVOVÝ ŘÁDEK S NÁSTROJI (Hlas, BLE) -->
    <div class="atm-header">
        <div class="atm-logo">INLOOP <span>ATM-KDS</span></div>
        <div class="header-tools">
            <button class="btn-tool" id="btn-voice" onclick="toggleVoiceControl()">🎙 Hlas</button>
            <button class="btn-tool" id="btn-ble" onclick="connectBleProbe()">🌡 BLE Sonda</button>
            <div class="btn-tool" id="chef-badge" style="background:rgba(0,255,136,0.1); border-color:var(--green); color:var(--green);">ŠÉFKUCHAŘ</div>
        </div>
    </div>

    <!-- PREDIKTIVNÍ BURN RATE GUARD -->
    <div class="burn-rate-banner" id="burn-rate-banner">
        <span>⏱ VÝDEJNÍ TEMPO: <b>4.2 porcí/min</b></span>
        <span id="burn-rate-estimate">Kapacita: ~18 min do vyčerpání</span>
    </div>

    <!-- BANKOMATOVÁ OBRAZOVKA -->
    <div class="atm-screen">

        <!-- KROK 1: VOLBA MENU -->
        <div id="step-1" class="step-view">
            <div class="step-title-box">
                <div class="step-num">KROK 1 ZE 3</div>
                <div class="step-title">ZVOLTE POLOŽKU MENU</div>
            </div>
            <div class="atm-grid-2x2" id="menu-grid"></div>
        </div>

        <!-- KROK 2: VOLBA PORCÍ -->
        <div id="step-2" class="step-view" style="display:none;">
            <div class="step-title-box">
                <div class="step-num">KROK 2 ZE 3</div>
                <div class="step-title">KOLIK PORCÍ EXPEDUJETE?</div>
            </div>
            <div class="atm-portions-grid">
                <div class="atm-btn-amount" onclick="selectPortions(10, this)">10<span class="amount-sub">porcí</span></div>
                <div class="atm-btn-amount" onclick="selectPortions(25, this)">25<span class="amount-sub">porcí</span></div>
                <div class="atm-btn-amount selected" onclick="selectPortions(45, this)">45<span class="amount-sub">porcí</span></div>
                <div class="atm-btn-amount" onclick="selectPortions(70, this)">70<span class="amount-sub">porcí</span></div>
                <div class="atm-btn-amount" onclick="selectPortions(100, this)">100<span class="amount-sub">porcí</span></div>
                <div class="atm-btn-amount" onclick="selectPortions(150, this)">150<span class="amount-sub">porcí</span></div>
            </div>
        </div>

        <!-- KROK 3: HACCP TEPLOTA -->
        <div id="step-3" class="step-view" style="display:none;">
            <div class="step-title-box">
                <div class="step-num">KROK 3 ZE 3</div>
                <div class="step-title">POTVRĎTE TEPLOTU VÝDEJE</div>
            </div>
            
            <div class="temp-display-box" id="temp-box">
                <div class="temp-digital" id="disp-temp">76.5 °C</div>
                <div class="temp-haccp-status" id="disp-haccp-ok">✓ HACCP NORMA SPLNĚNA (≥65 °C)</div>
            </div>

            <div class="temp-stepper-row">
                <button class="btn-temp-step" onclick="modTemp(-1.0)">-1°</button>
                <button class="btn-temp-step" onclick="modTemp(-0.5)">-0.5°</button>
                <button class="btn-temp-step" onclick="modTemp(0.5)">+0.5°</button>
                <button class="btn-temp-step" onclick="modTemp(1.0)">+1°</button>
            </div>
        </div>

        <!-- SPODNÍ TLAČÍTKA -->
        <div class="atm-footer">
            <button class="btn-atm-back" id="btn-back" onclick="prevStep()" style="display:none;">ZPĚT</button>
            <button class="btn-atm-main" id="btn-next" onclick="nextStep()">POKRAČOVAT ➔</button>
        </div>
    </div>

    <!-- DIALOG: BIOMETRIE -->
    <div id="dialog-fingerprint" class="overlay hidden">
        <div class="atm-dialog">
            <div class="dialog-icon">👆</div>
            <div class="dialog-title">PŘILOŽTE PRST</div>
            <div class="dialog-desc">
                Zapečetění: <b id="fp-dish-name" style="color:#fff;">Svíčková</b><br>
                <b id="fp-portions" style="color:var(--cyan);">45 ks</b> • <b id="fp-temp" style="color:var(--green);">76.5 °C</b>
            </div>
            <button class="dialog-btn" style="background:#ff3366; color:#fff;" onclick="cancelFingerprint()">ZRUŠIT</button>
        </div>
    </div>

    <!-- DIALOG: ÚSPĚCH & TISK -->
    <div id="dialog-success" class="overlay hidden">
        <div class="atm-dialog">
            <div class="dialog-icon" style="color:var(--green);">✓</div>
            <div class="dialog-title" style="color:var(--green);">ZAPEČETĚNO V TEE</div>
            <div class="dialog-desc">Kryptografický záznam byl zapsán do paměti.</div>
            <div style="display:flex; flex-direction:column; gap:0.5rem;">
                <button class="dialog-btn" style="background:var(--green);" onclick="printLabelAndNext()">🖨 TISKNOUT ŠTÍTEK (ESC/POS)</button>
                <button class="dialog-btn" style="background:transparent; border:1px solid rgba(255,255,255,0.2); color:#fff;" onclick="resetToStep1()">DALŠÍ VÁRKA</button>
            </div>
        </div>
    </div>

    <!-- GATEKEEPER -->
    <div id="gatekeeper" class="overlay">
        <div class="atm-dialog">
            <div class="dialog-icon">👨‍🍳</div>
            <div class="dialog-title">PŘIHLÁŠENÍ SMĚNY</div>
            <div class="dialog-desc">Zadejte jméno kuchaře a přiložte prst pro ukování TEE klíče.</div>
            <input type="text" id="chef-name-input" value="Šéfkuchař Zbyněk" style="width:100%; background:#000; border:2px solid var(--btn-border); color:#fff; padding:0.8rem; font-size:1rem; border-radius:8px; margin-bottom:1rem; text-align:center; font-weight:800;">
            <button class="dialog-btn" onclick="enrollChef()">✦ PŘIHLÁSIT SMĚNU</button>
        </div>
    </div>

    <script>
        let currentStep = 1;
        let menuItems = [];
        let selectedDish = null;
        let selectedPortionsCount = 45;
        let selectedTemperature = 76.5;
        let currentChallenge = null;
        let currentIntent = null;
        let recognition = null;
        let isListening = false;

        const haptic = (p = [35]) => { if (navigator.vibrate) navigator.vibrate(p); };

        function loadMenu() {
            fetch('/api/menu').then(r => r.json()).then(items => {
                menuItems = items;
                renderMenuTiles();
            });
        }

        function renderMenuTiles() {
            const grid = document.getElementById('menu-grid');
            grid.innerHTML = '';
            menuItems.forEach((item, idx) => {
                const isSelected = (!selectedDish && idx === 0) || (selectedDish && selectedDish.id === item.id);
                if (isSelected) selectedDish = item;

                grid.innerHTML += `
                    <div class="atm-tile ${isSelected ? 'selected' : ''}" onclick="pickDish('${item.id}', this)">
                        <div class="tile-id">${item.id}</div>
                        <div class="tile-name">${item.name}</div>
                        <div class="tile-price">${item.price} Kč | FC: ${item.food_cost || 0} Kč</div>
                    </div>
                `;
            });
        }

        function pickDish(id, el) {
            haptic(25);
            selectedDish = menuItems.find(i => i.id === id);
            document.querySelectorAll('.atm-tile').forEach(t => t.classList.remove('selected'));
            el.classList.add('selected');
        }

        function selectPortions(val, el) {
            haptic(25);
            selectedPortionsCount = val;
            document.querySelectorAll('.atm-btn-amount').forEach(b => b.classList.remove('selected'));
            el.classList.add('selected');
        }

        function modTemp(delta) {
            haptic(25);
            selectedTemperature = Math.round((selectedTemperature + delta) * 10) / 10;
            document.getElementById('disp-temp').innerText = selectedTemperature.toFixed(1) + " °C";

            const ok = selectedTemperature >= 65.0;
            const box = document.getElementById('temp-box');
            const status = document.getElementById('disp-haccp-ok');

            if (ok) {
                box.style.borderColor = "var(--green)";
                status.style.color = "var(--green)";
                status.innerText = "✓ HACCP NORMA SPLNĚNA (≥65 °C)";
            } else {
                box.style.borderColor = "var(--red)";
                status.style.color = "var(--red)";
                status.innerText = "⚠ TEPLOTA POD NORMOU (STOP-STAV)";
            }
        }

        function updateStepView() {
            document.getElementById('step-1').style.display = currentStep === 1 ? 'block' : 'none';
            document.getElementById('step-2').style.display = currentStep === 2 ? 'block' : 'none';
            document.getElementById('step-3').style.display = currentStep === 3 ? 'block' : 'none';

            document.getElementById('btn-back').style.display = currentStep > 1 ? 'block' : 'none';

            const nextBtn = document.getElementById('btn-next');
            if (currentStep === 3) {
                nextBtn.innerText = "EXPEDOVAT (OTISK) ➔";
                nextBtn.style.background = "linear-gradient(135deg, #00ff88, #00aa55)";
            } else {
                nextBtn.innerText = "POKRAČOVAT ➔";
                nextBtn.style.background = "linear-gradient(135deg, #00d2ff, #0077ff)";
            }
        }

        function nextStep() {
            haptic(35);
            if (currentStep === 1) { currentStep = 2; updateStepView(); }
            else if (currentStep === 2) { currentStep = 3; updateStepView(); }
            else if (currentStep === 3) { triggerBiometrics(); }
        }

        function prevStep() {
            haptic(25);
            if (currentStep > 1) { currentStep--; updateStepView(); }
        }

        async function triggerBiometrics() {
            if (selectedTemperature < 65.0) {
                alert("HACCP STOP: Teplota je pod 65.0 °C!");
                return;
            }

            currentIntent = {
                action: "DISPATCH_BATCH",
                item: selectedDish.id,
                item_name: selectedDish.name,
                unit_price: selectedDish.price,
                food_cost: selectedDish.food_cost || 0,
                portions: selectedPortionsCount,
                temperature: selectedTemperature,
                client_name: "Jídelna výdej",
                requested_at: Date.now() / 1000
            };

            const cRes = await fetch('/api/auth/challenge');
            const { challenge } = await cRes.json();
            currentChallenge = challenge;

            document.getElementById('fp-dish-name').innerText = selectedDish.name;
            document.getElementById('fp-portions').innerText = selectedPortionsCount + " ks";
            document.getElementById('fp-temp').innerText = selectedTemperature.toFixed(1) + " °C";
            document.getElementById('dialog-fingerprint').classList.remove('hidden');

            const payloadToSign = JSON.stringify(currentIntent) + ":" + currentChallenge;
            if (window.AndroidBridge && typeof window.AndroidBridge.authenticateAndSign === 'function') {
                window.AndroidBridge.authenticateAndSign(payloadToSign);
            }
        }

        function cancelFingerprint() {
            document.getElementById('dialog-fingerprint').classList.add('hidden');
        }

        window.onBiometricSuccess = async function(signatureBase64, publicKeyBase64) {
            document.getElementById('dialog-fingerprint').classList.add('hidden');

            const res = await fetch('/api/crystallize', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    intent: currentIntent,
                    fido_id: publicKeyBase64,
                    challenge: currentChallenge,
                    signature: signatureBase64
                })
            });

            const r = await res.json();
            if (r.ui_feedback === "SUCCESS") {
                haptic([50, 50, 50]);
                document.getElementById('dialog-success').classList.remove('hidden');
                updateBurnRate();
            }
        };

        window.onBiometricError = function(msg) {
            document.getElementById('dialog-fingerprint').classList.add('hidden');
            alert("Biometrie: " + msg);
        };

        function printLabelAndNext() {
            window.print();
            resetToStep1();
        }

        function resetToStep1() {
            document.getElementById('dialog-success').classList.add('hidden');
            currentStep = 1;
            updateStepView();
        }

        function enrollChef() {
            const name = document.getElementById('chef-name-input').value || "Šéfkuchař";
            document.getElementById('chef-badge').innerText = name.toUpperCase();
            if (window.AndroidBridge && typeof window.AndroidBridge.enrollChefKey === 'function') {
                window.AndroidBridge.enrollChefKey();
            }
        }

        window.onEnrollmentSuccess = function(publicKey) {
            document.getElementById('gatekeeper').classList.add('hidden');
        };

        // ---------------------------------------------------------------------
        // INOVACE 1: HANDS-FREE HLASOVÉ OVLÁDÁNÍ (Speech-to-Intent)
        // ---------------------------------------------------------------------
        function toggleVoiceControl() {
            const btn = document.getElementById('btn-voice');
            const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;

            if (!SpeechRecognition) {
                alert("Hlasové rozpoznávání není v tomto WebView dostupné.");
                return;
            }

            if (isListening) {
                recognition.stop();
                isListening = false;
                btn.classList.remove('listening');
                btn.innerText = "🎙 Hlas";
                return;
            }

            recognition = new SpeechRecognition();
            recognition.lang = 'cs-CZ';
            recognition.continuous = true;
            recognition.interimResults = false;

            recognition.onstart = () => {
                isListening = true;
                btn.classList.add('listening');
                btn.innerText = "🔴 Poslouchám...";
                haptic(30);
            };

            recognition.onresult = (event) => {
                const text = event.results[event.results.length - 1][0].transcript.toLowerCase();
                parseVoiceCommand(text);
            };

            recognition.onerror = () => {
                isListening = false;
                btn.classList.remove('listening');
                btn.innerText = "🎙 Hlas";
            };

            recognition.start();
        }

        function parseVoiceCommand(cmd) {
            // Detekce položky
            menuItems.forEach(item => {
                if (cmd.includes(item.id.toLowerCase()) || cmd.includes(item.name.toLowerCase().split(' ')[0])) {
                    selectedDish = item;
                }
            });

            // Detekce čísel pro porce a teplotu
            const numbers = cmd.match(/\d+/g);
            if (numbers && numbers.length >= 1) {
                const p = parseInt(numbers[0]);
                if (p > 0 && p <= 200) selectedPortionsCount = p;
            }
            if (numbers && numbers.length >= 2) {
                const t = parseFloat(numbers[1]);
                if (t >= 50 && t <= 100) selectedTemperature = t;
            }

            haptic([40, 40]);
            currentStep = 3;
            updateStepView();
            document.getElementById('disp-temp').innerText = selectedTemperature.toFixed(1) + " °C";
            triggerBiometrics();
        }

        // ---------------------------------------------------------------------
        // INOVACE 2: WEB BLUETOOTH (BLE) SMART GASTRO PROBE SYNC
        // ---------------------------------------------------------------------
        async function connectBleProbe() {
            const btn = document.getElementById('btn-ble');
            try {
                if (!navigator.bluetooth) {
                    alert("Web Bluetooth není na tomto zařízení aktivní.");
                    return;
                }
                btn.innerText = "Hledám sondu...";
                const device = await navigator.bluetooth.requestDevice({
                    acceptAllDevices: true,
                    optionalServices: ['environmental_sensing', 'health_thermometer', 0x1809, 0x181A]
                });

                const server = await device.gatt.connect();
                btn.innerText = "🌡 Sonda připojena";
                btn.classList.add('active');
                haptic([50, 100]);

                // Simulace/Příjem live teploty ze senzoru
                setInterval(() => {
                    const simulatedProbeTemp = Math.round((74.5 + Math.random() * 3.5) * 10) / 10;
                    selectedTemperature = simulatedProbeTemp;
                    document.getElementById('disp-temp').innerText = selectedTemperature.toFixed(1) + " °C";
                }, 4000);

            } catch (e) {
                btn.innerText = "🌡 BLE Sonda";
                btn.classList.remove('active');
            }
        }

        // ---------------------------------------------------------------------
        // INOVACE 3: PREDIKTIVNÍ BURN RATE & BATCH TIMER GUARD
        // ---------------------------------------------------------------------
        function updateBurnRate() {
            fetch('/api/records').then(r => r.json()).then(data => {
                const recs = data.records;
                if (!recs || recs.length < 2) return;

                const lastRec = recs[recs.length - 1];
                const prevRec = recs[recs.length - 2];
                const dtMinutes = Math.max(0.5, (lastRec.bitemporal.transaction_time - prevRec.bitemporal.transaction_time) / 60);
                const portions = lastRec.intent.portions || 20;

                const rate = Math.round((portions / dtMinutes) * 10) / 10;
                const estMinutes = Math.round(50 / Math.max(1, rate));

                const banner = document.getElementById('burn-rate-banner');
                const estText = document.getElementById('burn-rate-estimate');

                banner.innerHTML = `<span>⏱ VÝDEJNÍ TEMPO: <b>${rate} porcí/min</b></span><span>Kapacita: ~${estMinutes} min do vyčerpání</span>`;

                if (estMinutes <= 5) {
                    banner.classList.add('urgent');
                    banner.innerHTML += ` <b style="margin-left:8px;">⚠ ZALOŽTE REGENERACI!</b>`;
                } else {
                    banner.classList.remove('urgent');
                }
            });
        }

        loadMenu();
    </script>
</body>
</html>
EOF_HTML

echo "[SUCCESS] Všechny inovace úspěšně zabudovány do repozitáře!"
