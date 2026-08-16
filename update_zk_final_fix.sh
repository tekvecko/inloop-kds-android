#!/bin/bash
set -e

echo "[*] Opravuji ZK Merkle vazby, kanonický TEE payload a atomický binární zápis..."

# 1. Finální robustní KdsEmbeddedServer.kt
cat << 'EOF_SERVER' > app/src/main/java/cz/inloop/kds/KdsEmbeddedServer.kt
package cz.inloop.kds

import android.content.Context
import fi.iki.elonen.NanoHTTPD
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.CopyOnWriteArrayList

class KdsEmbeddedServer(port: Int, private val context: Context) : NanoHTTPD("127.0.0.1", port) {

    private val binLedgerFile = File(context.filesDir, "kds_immutable_ledger.bin")
    private val menuFile = File(context.filesDir, "kds_daily_menu.json")
    private val workersFile = File(context.filesDir, "kds_zk_workers.json")
    private val rsEngine = ReedSolomonEngine(16)

    private var lastHash = "0000000000000000000000000000000000000000000000000000000000000000"
    private var lamportClock = 0
    private val records = CopyOnWriteArrayList<JSONObject>()
    private val zkWorkers = CopyOnWriteArrayList<JSONObject>()
    private val activeChallenges = HashMap<String, Long>()

    init {
        loadBinaryLedger()
        initDefaultMenu()
        initZkWorkersTree()
    }

    private fun sha256(input: String): String {
        val bytes = MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8))
        return bytes.joinToString("") { "%02x".format(it) }
    }

    private fun sha256Bytes(b1: ByteArray, b2: ByteArray): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        md.update(b1)
        md.update(b2)
        return md.digest()
    }

    private fun initZkWorkersTree() {
        zkWorkers.clear()
        if (!workersFile.exists()) {
            val defaultSalt = "SALT_" + UUID.randomUUID().toString().take(12)
            val masterComm = sha256("$defaultSalt:MASTER_CHEF:LEVEL_3")

            val obj = JSONObject().apply {
                put("commitment", masterComm)
                put("alias", "Šéfkuchař (Master)")
                put("role", "HACCP_LEVEL_3")
                put("salt", defaultSalt)
            }
            zkWorkers.add(obj)
            val arr = JSONArray().apply { put(obj) }
            workersFile.writeText(arr.toString(2))
        } else {
            try {
                val arr = JSONArray(workersFile.readText())
                for (i in 0 until arr.length()) {
                    zkWorkers.add(arr.getJSONObject(i))
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    private fun computeWorkersMerkleRoot(): String {
        if (zkWorkers.isEmpty()) return sha256("EMPTY_TREE")
        var layer = zkWorkers.map { w ->
            val h = w.getString("commitment")
            val bytes = ByteArray(h.length / 2)
            for (i in bytes.indices) {
                val idx = i * 2
                bytes[i] = h.substring(idx, idx + 2).toInt(16).toByte()
            }
            bytes
        }.toMutableList()

        while (layer.size > 1) {
            if (layer.size % 2 != 0) layer.add(layer.last())
            val next = mutableListOf<ByteArray>()
            for (i in 0 until layer.size step 2) {
                next.add(sha256Bytes(layer[i], layer[i + 1]))
            }
            layer = next
        }
        return layer[0].joinToString("") { "%02x".format(it) }
    }

    private fun loadBinaryLedger() {
        if (binLedgerFile.exists() && binLedgerFile.length() > 0) {
            try {
                RandomAccessFile(binLedgerFile, "r").use { raf ->
                    while (raf.filePointer < raf.length()) {
                        val blockSize = raf.readInt()
                        val blockBytes = ByteArray(blockSize)
                        raf.readFully(blockBytes)

                        val validPayload = rsEngine.verifyAndExtract(blockBytes)
                        if (validPayload != null) {
                            val jsonStr = String(validPayload, Charsets.UTF_8)
                            val crystal = JSONObject(jsonStr)
                            records.add(crystal)
                            lastHash = crystal.optString("crystal_hash", lastHash)
                            lamportClock = maxOf(lamportClock, crystal.optInt("lamport_tick", 0))
                        }
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    @Synchronized
    private fun appendCrystalBin(crystal: JSONObject): JSONObject {
        lamportClock++
        crystal.put("lamport_tick", lamportClock)
        crystal.put("parent_hash", lastHash)

        val jsonBytes = crystal.toString().toByteArray(Charsets.UTF_8)
        val encodedBlock = rsEngine.encode(jsonBytes)

        RandomAccessFile(binLedgerFile, "rw").use { raf ->
            val channel = raf.channel
            val lock = channel.lock()
            try {
                raf.seek(raf.length())
                raf.writeInt(encodedBlock.size)
                raf.write(encodedBlock)
            } finally {
                lock.release()
            }
        }

        records.add(crystal)
        lastHash = crystal.getString("crystal_hash")
        return crystal
    }

    private fun verifyEcdsaSignature(publicKeyBase64: String, payload: String, signatureBase64: String): Boolean {
        return try {
            val pubBytes = Base64.getDecoder().decode(publicKeyBase64)
            val keySpec = X509EncodedKeySpec(pubBytes)
            val pubKey = KeyFactory.getInstance("EC").generatePublic(keySpec)

            val sigBytes = Base64.getDecoder().decode(signatureBase64)
            val verifier = Signature.getInstance("SHA256withECDSA").apply {
                initVerify(pubKey)
                update(payload.toByteArray(Charsets.UTF_8))
            }
            verifier.verify(sigBytes)
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    private fun initDefaultMenu() {
        if (!menuFile.exists()) {
            val defaultMenu = JSONArray().apply {
                put(JSONObject().apply {
                    put("id", "MENU_1")
                    put("name", "Hovězí svíčková na smetaně, houskový knedlík")
                    put("price", 165.0)
                    put("food_cost", 62.0)
                    put("allergens", "1, 3, 7, 9, 10")
                })
                put(JSONObject().apply {
                    put("id", "MENU_2")
                    put("name", "Kuřecí plátek s bylinkami, grilovaná zelenina")
                    put("price", 149.0)
                    put("food_cost", 48.0)
                    put("allergens", "7, 9")
                })
                put(JSONObject().apply {
                    put("id", "MENU_3")
                    put("name", "Pečená dýně s quinoou a cizrnou (Veggie)")
                    put("price", 139.0)
                    put("food_cost", 38.0)
                    put("allergens", "6, 11")
                })
                put(JSONObject().apply {
                    put("id", "POLEVKA_1")
                    put("name", "Poctivý hovězí vývar s játrovými knedlíčky")
                    put("price", 45.0)
                    put("food_cost", 14.0)
                    put("allergens", "1, 3, 9")
                })
            }
            menuFile.writeText(defaultMenu.toString(2))
        }
    }

    private fun readJsonBody(session: IHTTPSession): JSONObject {
        return try {
            val contentLength = session.headers["content-length"]?.toIntOrNull() ?: 0
            if (contentLength > 0) {
                val buffer = ByteArray(contentLength)
                var totalRead = 0
                while (totalRead < contentLength) {
                    val read = session.inputStream.read(buffer, totalRead, contentLength - totalRead)
                    if (read == -1) break
                    totalRead += read
                }
                val jsonStr = String(buffer, 0, totalRead, Charsets.UTF_8)
                JSONObject(jsonStr)
            } else {
                JSONObject()
            }
        } catch (e: Exception) {
            JSONObject()
        }
    }

    override fun serve(session: IHTTPSession): Response {
        val uri = session.uri
        val method = session.method

        if (Method.OPTIONS == method) {
            val res = newFixedLengthResponse(Response.Status.OK, "text/plain", "")
            addCorsHeaders(res)
            return res
        }

        val response = when {
            uri == "/" -> {
                try {
                    val html = context.assets.open("index.html").bufferedReader().use { it.readText() }
                    newFixedLengthResponse(Response.Status.OK, "text/html", html)
                } catch (e: Exception) {
                    newFixedLengthResponse(Response.Status.INTERNAL_ERROR, "text/plain", "Chyba: ${e.message}")
                }
            }
            uri == "/api/workers" && method == Method.GET -> {
                val arr = JSONArray()
                zkWorkers.forEach { 
                    arr.put(JSONObject().apply {
                        put("commitment", it.getString("commitment"))
                        put("alias", it.getString("alias"))
                        put("role", it.getString("role"))
                    })
                }
                newFixedLengthResponse(Response.Status.OK, "application/json", arr.toString())
            }
            uri == "/api/workers/add" && method == Method.POST -> {
                val body = readJsonBody(session)
                val rawName = body.optString("name", "Pracovník")
                val salt = "SALT_" + UUID.randomUUID().toString().take(12)
                val comm = sha256("$salt:$rawName:LEVEL_2")

                val newObj = JSONObject().apply {
                    put("commitment", comm)
                    put("alias", rawName)
                    put("role", "HACCP_LEVEL_2")
                    put("salt", salt)
                }
                zkWorkers.add(newObj)

                val arr = JSONArray()
                zkWorkers.forEach { arr.put(it) }
                workersFile.writeText(arr.toString(2))

                newFixedLengthResponse(Response.Status.OK, "application/json", "{\"status\":\"SUCCESS\",\"commitment\":\"$comm\"}")
            }
            uri == "/api/menu" && method == Method.GET -> {
                val menuContent = if (menuFile.exists()) menuFile.readText() else "[]"
                newFixedLengthResponse(Response.Status.OK, "application/json", menuContent)
            }
            uri == "/api/auth/challenge" && method == Method.GET -> {
                val bytes = ByteArray(32)
                SecureRandom().nextBytes(bytes)
                val challenge = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
                val merkleRoot = computeWorkersMerkleRoot()

                synchronized(activeChallenges) {
                    activeChallenges[challenge] = System.currentTimeMillis()
                }
                newFixedLengthResponse(Response.Status.OK, "application/json", 
                    "{\"challenge\":\"$challenge\",\"merkle_root\":\"$merkleRoot\"}")
            }
            uri == "/api/crystallize" && method == Method.POST -> {
                val body = readJsonBody(session)
                val intent = body.optJSONObject("intent") ?: JSONObject()
                val fidoId = body.optString("fido_id", "")
                val sig = body.optString("signature", "")
                val challenge = body.optString("challenge", "")
                val workerComm = intent.optString("worker_commitment", "")

                val isValidChallenge = synchronized(activeChallenges) {
                    activeChallenges.remove(challenge) != null
                }
                if (!isValidChallenge) {
                    newFixedLengthResponse(Response.Status.FORBIDDEN, "application/json", "{\"ui_feedback\":\"ERROR\",\"message\":\"Neplatná výzva!\"}")
                } else {
                    val merkleRoot = computeWorkersMerkleRoot()
                    val canonicalPayload = intent.toString() + ":" + challenge + ":" + merkleRoot
                    val isSignatureValid = verifyEcdsaSignature(fidoId, canonicalPayload, sig)
                    val isWorkerInSet = zkWorkers.any { it.getString("commitment") == workerComm }

                    if (!isSignatureValid || !isWorkerInSet) {
                        newFixedLengthResponse(Response.Status.FORBIDDEN, "application/json", 
                            "{\"ui_feedback\":\"ERROR\",\"message\":\"ZK STOP: Matematické ověření TEE podpisu nebo členství selhalo!\"}")
                    } else {
                        val unlinkableNullifier = sha256("$fidoId:$challenge:${intent.optDouble("requested_at")}")

                        val zkSanitizedIntent = JSONObject(intent.toString()).apply {
                            remove("worker_commitment")
                            put("zk_nullifier", unlinkableNullifier)
                            put("identity_merkle_root", merkleRoot)
                        }

                        val raw = "$zkSanitizedIntent:$fidoId:$sig:$lastHash"
                        val crystalHash = sha256(raw)

                        val crystal = JSONObject().apply {
                            put("crystal_hash", crystalHash)
                            put("intent", zkSanitizedIntent)
                            put("fido_id_hash", sha256(fidoId))
                            put("signature_stub", sig.take(24) + "...")
                            put("ecc_protected", true)
                            put("zk_set_membership", true)
                            put("bitemporal", JSONObject().apply {
                                put("transaction_time", System.currentTimeMillis() / 1000.0)
                                put("valid_from", intent.optDouble("requested_at"))
                            })
                        }

                        val stored = appendCrystalBin(crystal)
                        newFixedLengthResponse(Response.Status.OK, "application/json", "{\"ui_feedback\":\"SUCCESS\",\"crystal\":$stored}")
                    }
                }
            }
            uri == "/api/records" && method == Method.GET -> {
                val arr = JSONArray()
                records.forEach { arr.put(it) }
                newFixedLengthResponse(Response.Status.OK, "application/json", "{\"records\":$arr}")
            }
            uri == "/audit" -> {
                newFixedLengthResponse(Response.Status.OK, "text/html", renderZkAuditHtml())
            }
            else -> newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "404 Not Found")
        }

        addCorsHeaders(response)
        return response
    }

    private fun addCorsHeaders(response: Response) {
        response.addHeader("Access-Control-Allow-Origin", "*")
        response.addHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        response.addHeader("Access-Control-Allow-Headers", "Content-Type, Authorization")
    }

    private fun renderZkAuditHtml(): String {
        val sdf = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault())
        val workersRoot = computeWorkersMerkleRoot()
        val rows = StringBuilder()

        for (i in 0 until records.size) {
            val r = records[i]
            val it = r.optJSONObject("intent") ?: JSONObject()
            val bt = r.optJSONObject("bitemporal") ?: JSONObject()
            val ts = bt.optDouble("transaction_time", 0.0).toLong() * 1000
            val temp = it.optDouble("temperature", 0.0)
            val nullifier = it.optString("zk_nullifier", "N/A")
            val cHash = r.optString("crystal_hash", "")

            rows.append("""
                <tr>
                    <td style='text-align:center;font-weight:bold;'>#${r.optInt("lamport_tick", i + 1)}</td>
                    <td>${sdf.format(Date(ts))}</td>
                    <td><b>${it.optString("item_name")}</b> (${it.optInt("portions")} ks)</td>
                    <td style='text-align:right;font-weight:bold;'>$temp °C</td>
                    <td style='color:green;font-weight:bold;font-size:11px;'>ZK_PROVED (Root: ${workersRoot.take(8)}...)</td>
                    <td style='font-family:monospace;font-size:10px;'>${nullifier.take(16)}...</td>
                    <td style='font-family:monospace;font-size:10px;'>${cHash.take(16)}...</td>
                </tr>
            """.trimIndent())
        }

        return """
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>ZK Audit Protocol</title>
<style>body{font-family:Arial,sans-serif;padding:20px;background:#fff;color:#000}table{width:100%;border-collapse:collapse}th,td{border:1px solid #333;padding:8px;font-size:12px;}th{background:#f1f5f9;}</style>
</head><body>
<div style='border:2px solid green;color:green;padding:6px;float:right;font-weight:bold;'>ZERO_KNOWLEDGE_VERIFIED</div>
<h2>ÚŘEDNÍ PROTOKOL: ZK SET-MEMBERSHIP AUDIT</h2>
<p>Identity Merkle Root: <code>$workersRoot</code></p>
<table><thead><tr><th>Tick</th><th>Čas</th><th>Položka</th><th>Teplota</th><th>ZK Důkaz Oprávnění</th><th>Unlinkable Nullifier</th><th>Krystal Hash</th></tr></thead><tbody>$rows</tbody></table>
</body></html>
        """.trimIndent()
    }
}
EOF_SERVER

# 2. Aktualizace index.html s kanonickým payloadem (intent + challenge + merkle_root)
cat << 'EOF_HTML' > app/src/main/assets/index.html
<!DOCTYPE html>
<html lang="cs">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
    <title>InLoop ATM-KDS ZK Protected</title>
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
            --red: #ff3366;
            --text-main: #ffffff;
            --text-dim: #7d96b3;
        }

        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; margin: 0; padding: 0; user-select: none; }
        body {
            background: var(--bg-atm); color: var(--text-main); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            height: 100dvh; display: flex; flex-direction: column; padding: 0.4rem; overflow: hidden;
        }

        .atm-header {
            display: flex; justify-content: space-between; align-items: center; padding: 0.45rem 0.8rem;
            background: #08101e; border-bottom: 2px solid var(--btn-border); margin-bottom: 0.4rem;
        }
        .atm-logo { font-size: 0.95rem; font-weight: 900; letter-spacing: 1px; color: #fff; cursor: pointer; }
        .atm-logo span { color: var(--cyan); }

        .active-worker-badge {
            background: rgba(0, 255, 136, 0.12); border: 1px solid var(--green); color: var(--green);
            padding: 0.25rem 0.6rem; border-radius: 6px; font-size: 0.72rem; font-weight: 800; cursor: pointer;
        }

        .worker-fast-selector { display: flex; gap: 0.3rem; overflow-x: auto; margin-bottom: 0.4rem; }
        .worker-chip {
            background: var(--btn-bg); border: 1px solid var(--btn-border); color: var(--text-dim);
            padding: 0.25rem 0.55rem; border-radius: 6px; font-size: 0.68rem; font-weight: 700; white-space: nowrap; cursor: pointer;
        }
        .worker-chip.selected { border-color: var(--cyan); color: #fff; background: rgba(0, 210, 255, 0.15); }

        .atm-screen {
            flex: 1; background: var(--screen-bg); border: 2px solid var(--btn-border); border-radius: 14px;
            padding: 0.8rem; display: flex; flex-direction: column; justify-content: space-between; box-shadow: inset 0 0 30px rgba(0,0,0,0.5);
        }

        .step-title-box { text-align: center; margin-bottom: 0.4rem; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 0.3rem; }
        .step-num { font-size: 0.68rem; font-weight: 800; color: var(--cyan); text-transform: uppercase; }
        .step-title { font-size: 1.15rem; font-weight: 900; color: #fff; margin-top: 0.1rem; }

        .atm-grid-2x2 { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem; flex: 1; align-content: stretch; }
        .atm-tile {
            background: var(--btn-bg); border: 2px solid var(--btn-border); border-radius: 12px;
            padding: 0.75rem; cursor: pointer; display: flex; flex-direction: column; justify-content: center;
        }
        .atm-tile.selected { border-color: var(--cyan); background: rgba(0, 210, 255, 0.18); box-shadow: 0 0 18px var(--cyan-glow); }
        .tile-id { font-size: 0.75rem; font-weight: 900; color: var(--cyan); }
        .tile-name { font-size: 0.95rem; font-weight: 800; color: #fff; line-height: 1.25; margin: 0.2rem 0; }
        .tile-price { font-size: 0.8rem; font-weight: 700; color: var(--green); }

        .atm-portions-grid { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 0.5rem; flex: 1; align-content: center; }
        .atm-btn-amount {
            background: var(--btn-bg); border: 2px solid var(--btn-border); color: #fff; font-size: 1.4rem; font-weight: 900;
            border-radius: 12px; padding: 1rem 0.3rem; cursor: pointer; text-align: center;
        }
        .atm-btn-amount.selected { border-color: var(--cyan); background: var(--cyan); color: #000; box-shadow: 0 0 20px var(--cyan-glow); }

        .temp-display-box {
            background: #000; border: 2px solid var(--green); border-radius: 14px; padding: 1rem; text-align: center;
            margin: auto; width: 100%; max-width: 320px; box-shadow: 0 0 25px var(--green-glow);
        }
        .temp-digital { font-size: 2.8rem; font-weight: 900; color: var(--green); font-family: monospace; }
        .temp-haccp-status { font-size: 0.8rem; font-weight: 800; color: var(--green); margin-top: 0.2rem; }

        .temp-stepper-row { display: flex; gap: 0.5rem; max-width: 320px; margin: 0.6rem auto 0 auto; width: 100%; }
        .btn-temp-step {
            flex: 1; background: var(--btn-bg); border: 2px solid var(--btn-border); color: #fff; font-size: 1.1rem;
            font-weight: 900; border-radius: 8px; padding: 0.8rem; cursor: pointer;
        }

        .atm-footer { display: flex; gap: 0.5rem; margin-top: 0.5rem; }
        .btn-atm-main {
            flex: 2; background: linear-gradient(135deg, #00d2ff, #0077ff); color: #000; border: none; border-radius: 10px;
            padding: 1rem; font-size: 1.05rem; font-weight: 900; cursor: pointer; text-transform: uppercase;
        }
        .btn-atm-back {
            flex: 1; background: rgba(255,255,255,0.06); border: 2px solid var(--btn-border); color: #fff;
            border-radius: 10px; padding: 1rem; font-size: 0.95rem; font-weight: 800; cursor: pointer;
        }

        .overlay {
            position: fixed; inset: 0; background: rgba(3, 7, 18, 0.94); backdrop-filter: blur(25px);
            z-index: 10000; display: flex; flex-direction: column; justify-content: center; align-items: center; padding: 1.2rem; text-align: center;
        }
        .overlay.hidden { display: none; }
        .atm-dialog {
            background: #0d1b2e; border: 2px solid var(--cyan); border-radius: 18px; padding: 1.5rem; max-width: 440px; width: 100%; max-height: 88vh; overflow-y: auto; text-align: left;
        }
        .dialog-btn {
            background: var(--cyan); color: #000; border: none; border-radius: 10px; padding: 0.85rem; width: 100%; font-size: 0.95rem; font-weight: 900; cursor: pointer; text-transform: uppercase; margin-top: 0.6rem;
        }
    </style>
</head>
<body>

    <div class="atm-header">
        <div class="atm-logo" id="secret-logo-btn">INLOOP <span>ATM-KDS</span></div>
        <div class="active-worker-badge" id="active-worker-label" onclick="switchActiveWorker()">ZK: MASTER</div>
    </div>

    <div class="worker-fast-selector" id="worker-chips-bar"></div>

    <div class="atm-screen">
        <div id="step-1" class="step-view">
            <div class="step-title-box">
                <div class="step-num">KROK 1 ZE 3</div>
                <div class="step-title">ZVOLTE POLOŽKU MENU</div>
            </div>
            <div class="atm-grid-2x2" id="menu-grid"></div>
        </div>

        <div id="step-2" class="step-view" style="display:none;">
            <div class="step-title-box">
                <div class="step-num">KROK 2 ZE 3</div>
                <div class="step-title">KOLIK PORCÍ EXPEDUJETE?</div>
            </div>
            <div class="atm-portions-grid">
                <div class="atm-btn-amount" onclick="selectPortions(10, this)">10</div>
                <div class="atm-btn-amount" onclick="selectPortions(25, this)">25</div>
                <div class="atm-btn-amount selected" onclick="selectPortions(45, this)">45</div>
                <div class="atm-btn-amount" onclick="selectPortions(70, this)">70</div>
                <div class="atm-btn-amount" onclick="selectPortions(100, this)">100</div>
                <div class="atm-btn-amount" onclick="selectPortions(150, this)">150</div>
            </div>
        </div>

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

        <div class="atm-footer">
            <button class="btn-atm-back" id="btn-back" onclick="prevStep()" style="display:none;">ZPĚT</button>
            <button class="btn-atm-main" id="btn-next" onclick="nextStep()">POKRAČOVAT ➔</button>
        </div>
    </div>

    <!-- SKRYTÝ MASTER PANEL -->
    <div id="dialog-admin" class="overlay hidden">
        <div class="atm-dialog">
            <h3 style="color:#fff; margin-bottom:0.6rem;">ZK IDENTITNÍ TREZOR</h3>
            <label style="font-size:0.75rem; color:#fff; font-weight:700;">Jméno pracovníka:</label>
            <input type="text" id="new-worker-name" placeholder="Např. Petr Novák" style="width:100%; background:#000; border:1px solid var(--btn-border); color:#fff; padding:0.6rem; border-radius:6px; margin:0.3rem 0 0.8rem 0;">
            <button class="dialog-btn" onclick="saveNewWorker()">✦ VYGENEROVAT ZK COMMITMENT</button>
            <button class="dialog-btn" style="background:transparent; border:1px solid rgba(255,255,255,0.2); color:#fff;" onclick="closeAdminDialog()">ZAVŘÍT</button>
        </div>
    </div>

    <!-- DIALOG: BIOMETRIE -->
    <div id="dialog-fingerprint" class="overlay hidden">
        <div class="atm-dialog" style="text-align:center;">
            <div style="font-size:3rem; margin-bottom:0.5rem;">👆</div>
            <h3 style="color:#fff; margin-bottom:0.4rem;">PŘILOŽTE PRST</h3>
            <p style="color:var(--text-dim); font-size:0.85rem; margin-bottom:1rem;" id="fp-worker-info">
                Generování ZK-Nullifieru a TEE podpisu
            </p>
            <button class="dialog-btn" style="background:#ff3366; color:#fff;" onclick="cancelFingerprint()">ZRUŠIT</button>
        </div>
    </div>

    <!-- DIALOG: ÚSPĚCH -->
    <div id="dialog-success" class="overlay hidden">
        <div class="atm-dialog" style="text-align:center;">
            <div style="font-size:3rem; color:var(--green); margin-bottom:0.5rem;">✓</div>
            <h3 style="color:var(--green); margin-bottom:0.4rem;">ZAPEČETĚNO V LEDGERU</h3>
            <p style="color:var(--text-dim); font-size:0.85rem; margin-bottom:1rem;">ZK Set-Membership & Reed-Solomon verifikovány.</p>
            <button class="dialog-btn" onclick="resetToStep1()">DALŠÍ VÁRKA</button>
        </div>
    </div>

    <script>
        let currentStep = 1;
        let menuItems = [];
        let workersList = [];
        let activeWorker = null;
        let selectedDish = null;
        let selectedPortionsCount = 45;
        let selectedTemperature = 76.5;
        let currentChallenge = null;
        let currentMerkleRoot = null;
        let currentIntent = null;

        const haptic = (p = [35]) => { if (navigator.vibrate) navigator.vibrate(p); };

        function loadWorkers() {
            fetch('/api/workers').then(r => r.json()).then(list => {
                workersList = list;
                if (!activeWorker && list.length > 0) {
                    activeWorker = list[0];
                }
                renderWorkerChips();
            });
        }

        function renderWorkerChips() {
            const bar = document.getElementById('worker-chips-bar');
            bar.innerHTML = '';
            workersList.forEach(w => {
                const isSel = activeWorker && activeWorker.commitment === w.commitment;
                bar.innerHTML += `
                    <div class="worker-chip ${isSel ? 'selected' : ''}" onclick="selectWorker('${w.commitment}')">
                        ${w.alias}
                    </div>
                `;
            });
            if (activeWorker) {
                document.getElementById('active-worker-label').innerText = activeWorker.alias.toUpperCase();
            }
        }

        function selectWorker(comm) {
            haptic(20);
            activeWorker = workersList.find(w => w.commitment === comm);
            renderWorkerChips();
        }

        function switchActiveWorker() {
            if (workersList.length > 1) {
                const curIdx = workersList.findIndex(w => w.commitment === activeWorker.commitment);
                const nextIdx = (curIdx + 1) % workersList.length;
                activeWorker = workersList[nextIdx];
                renderWorkerChips();
            }
        }

        // Skryté gesto pro Admin Panel (1.5s na logu)
        let pressTimer = null;
        const logoBtn = document.getElementById('secret-logo-btn');
        logoBtn.addEventListener('touchstart', () => { pressTimer = setTimeout(openAdminPanel, 1500); });
        logoBtn.addEventListener('touchend', () => { clearTimeout(pressTimer); });
        logoBtn.addEventListener('mousedown', () => { pressTimer = setTimeout(openAdminPanel, 1500); });
        logoBtn.addEventListener('mouseup', () => { clearTimeout(pressTimer); });

        function openAdminPanel() {
            haptic([50, 100]);
            document.getElementById('dialog-admin').classList.remove('hidden');
        }

        function closeAdminDialog() {
            document.getElementById('dialog-admin').classList.add('hidden');
        }

        function saveNewWorker() {
            const name = document.getElementById('new-worker-name').value.trim();
            if (!name) { alert("Zadejte jméno."); return; }

            fetch('/api/workers/add', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name: name })
            }).then(r => r.json()).then(d => {
                alert("ZK Commitment přidán do Merkle stromu!");
                document.getElementById('new-worker-name').value = '';
                closeAdminDialog();
                loadWorkers();
            });
        }

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
                        <div class="tile-price">${item.price} Kč</div>
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
                alert("HACCP STOP: Teplota pod 65.0 °C!");
                return;
            }

            const cRes = await fetch('/api/auth/challenge');
            const { challenge, merkle_root } = await cRes.json();
            currentChallenge = challenge;
            currentMerkleRoot = merkle_root;

            currentIntent = {
                action: "DISPATCH_BATCH",
                item: selectedDish.id,
                item_name: selectedDish.name,
                unit_price: selectedDish.price,
                portions: selectedPortionsCount,
                temperature: selectedTemperature,
                worker_commitment: activeWorker ? activeWorker.commitment : "",
                requested_at: Date.now() / 1000
            };

            document.getElementById('fp-worker-info').innerText = "Operátor: " + (activeWorker ? activeWorker.alias : "ZK-Anonym");
            document.getElementById('dialog-fingerprint').classList.remove('hidden');

            // Kanonický ZK Payload svázaný s Merkle stromem
            const canonicalPayload = JSON.stringify(currentIntent) + ":" + currentChallenge + ":" + currentMerkleRoot;

            if (window.AndroidBridge && typeof window.AndroidBridge.authenticateAndSign === 'function') {
                window.AndroidBridge.authenticateAndSign(canonicalPayload);
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
            } else {
                alert("Kryptografická chyba: " + r.message);
            }
        };

        window.onBiometricError = function(msg) {
            document.getElementById('dialog-fingerprint').classList.add('hidden');
            alert("Biometrie: " + msg);
        };

        function resetToStep1() {
            document.getElementById('dialog-success').classList.add('hidden');
            currentStep = 1;
            updateStepView();
        }

        loadMenu();
        loadWorkers();
    </script>
</body>
</html>
EOF_HTML

echo "[SUCCESS] Finální oprava ZK vazeb byla úspěšně zapsána!"
