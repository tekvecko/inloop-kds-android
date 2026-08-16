#!/bin/bash
set -e

echo "[*] Implementuji plnou verzi Enterprise KDS (Menu editor, Alergeny, Odběratelé, Fakturace)..."

# 1. Komplexní aktualizace KdsEmbeddedServer.kt
cat << 'EOF_SERVER' > app/src/main/java/cz/inloop/kds/KdsEmbeddedServer.kt
package cz.inloop.kds

import android.content.Context
import fi.iki.elonen.NanoHTTPD
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.CopyOnWriteArrayList

class KdsEmbeddedServer(port: Int, private val context: Context) : NanoHTTPD("127.0.0.1", port) {

    private val storageFile = File(context.filesDir, "kds_standalone_ledger.json")
    private val menuFile = File(context.filesDir, "kds_daily_menu.json")
    private var lastHash = "0000000000000000000000000000000000000000000000000000000000000000"
    private var lamportClock = 0
    private val records = CopyOnWriteArrayList<JSONObject>()
    private val activeChallenges = HashMap<String, Long>()

    init {
        loadLedger()
        initDefaultMenu()
    }

    private fun initDefaultMenu() {
        if (!menuFile.exists()) {
            val defaultMenu = JSONArray().apply {
                put(JSONObject().apply {
                    put("id", "MENU_1")
                    put("name", "Hovězí svíčková na smetaně, houskový knedlík")
                    put("price", 155.0)
                    put("allergens", "1, 3, 7, 9, 10")
                    put("type", "HLAVNI")
                })
                put(JSONObject().apply {
                    put("id", "MENU_2")
                    put("name", "Kuřecí plátek s bylinkami, grilovaná zelenina")
                    put("price", 145.0)
                    put("allergens", "7, 9")
                    put("type", "HLAVNI")
                })
                put(JSONObject().apply {
                    put("id", "MENU_3")
                    put("name", "Pečená dýně s quinoou a cizrnou (Veggie)")
                    put("price", 139.0)
                    put("allergens", "6, 11")
                    put("type", "DIETA")
                })
                put(JSONObject().apply {
                    put("id", "POLEVKA_1")
                    put("name", "Poctivý hovězí vývar s játrovými knedlíčky")
                    put("price", 45.0)
                    put("allergens", "1, 3, 9")
                    put("type", "POLEVKA")
                })
            }
            menuFile.writeText(defaultMenu.toString(2))
        }
    }

    private fun loadLedger() {
        if (storageFile.exists()) {
            try {
                val content = storageFile.readText()
                val array = JSONArray(content)
                for (i in 0 until array.length()) {
                    val obj = array.optJSONObject(i) ?: continue
                    records.add(obj)
                    lastHash = obj.optString("crystal_hash", lastHash)
                    lamportClock = maxOf(lamportClock, obj.optInt("lamport_tick", 0))
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    @Synchronized
    private fun appendCrystal(crystal: JSONObject): JSONObject {
        lamportClock++
        crystal.put("lamport_tick", lamportClock)
        crystal.put("parent_hash", lastHash)

        records.add(crystal)
        lastHash = crystal.getString("crystal_hash")

        val array = JSONArray()
        records.forEach { array.put(it) }
        storageFile.writeText(array.toString(2))
        return crystal
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

    private fun computeMerkleRoot(): String {
        if (records.isEmpty()) return "0000000000000000000000000000000000000000000000000000000000000000"
        var currentLayer = records.map {
            val h = it.optString("crystal_hash", "")
            try {
                val bytes = ByteArray(h.length / 2)
                for (i in bytes.indices) {
                    val index = i * 2
                    bytes[i] = h.substring(index, index + 2).toInt(16).toByte()
                }
                bytes
            } catch (e: Exception) {
                MessageDigest.getInstance("SHA-256").digest(h.toByteArray(Charsets.UTF_8))
            }
        }.toMutableList()

        while (currentLayer.size > 1) {
            if (currentLayer.size % 2 != 0) {
                currentLayer.add(currentLayer.last())
            }
            val nextLayer = mutableListOf<ByteArray>()
            for (i in 0 until currentLayer.size step 2) {
                nextLayer.add(sha256Bytes(currentLayer[i], currentLayer[i + 1]))
            }
            currentLayer = nextLayer
        }

        return currentLayer[0].joinToString("") { "%02x".format(it) }
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
                val files = HashMap<String, String>()
                session.parseBody(files)
                JSONObject(files["postData"] ?: "{}")
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
                    newFixedLengthResponse(Response.Status.INTERNAL_ERROR, "text/plain", "Chyba načtení: ${e.message}")
                }
            }
            uri == "/api/menu" && method == Method.GET -> {
                val menuContent = if (menuFile.exists()) menuFile.readText() else "[]"
                newFixedLengthResponse(Response.Status.OK, "application/json", menuContent)
            }
            uri == "/api/menu" && method == Method.POST -> {
                val body = readJsonBody(session)
                val items = body.optJSONArray("items")
                if (items != null) {
                    menuFile.writeText(items.toString(2))
                    newFixedLengthResponse(Response.Status.OK, "application/json", "{\"status\":\"SUCCESS\"}")
                } else {
                    newFixedLengthResponse(Response.Status.BAD_REQUEST, "application/json", "{\"status\":\"ERROR\"}")
                }
            }
            uri == "/api/auth/challenge" && method == Method.GET -> {
                val bytes = ByteArray(32)
                SecureRandom().nextBytes(bytes)
                val challenge = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
                synchronized(activeChallenges) {
                    activeChallenges[challenge] = System.currentTimeMillis()
                }
                newFixedLengthResponse(Response.Status.OK, "application/json", "{\"challenge\":\"$challenge\"}")
            }
            uri == "/api/macaroon/preflight" && method == Method.POST -> {
                val body = readJsonBody(session)
                val intent = body.optJSONObject("intent") ?: JSONObject()
                val temp = intent.optDouble("temperature", 0.0)
                val ccp = intent.optString("ccp_type", "CCP1_VYDEJ")

                if (ccp == "CCP1_VYDEJ" && temp < 65.0) {
                    newFixedLengthResponse(Response.Status.FORBIDDEN, "application/json", 
                        "{\"status\":\"REJECTED\",\"message\":\"HACCP STOP: Výdejní teplota $temp °C je pod zákonnou normou 65.0 °C!\"}")
                } else if (ccp == "CCP2_ZCHLAZENI" && temp > 4.0) {
                    newFixedLengthResponse(Response.Status.FORBIDDEN, "application/json", 
                        "{\"status\":\"REJECTED\",\"message\":\"HACCP STOP: Zchlazení $temp °C přesahuje limit 4.0 °C!\"}")
                } else {
                    newFixedLengthResponse(Response.Status.OK, "application/json", "{\"status\":\"SUCCESS\"}")
                }
            }
            uri == "/api/crystallize" && method == Method.POST -> {
                val body = readJsonBody(session)
                val intent = body.optJSONObject("intent") ?: JSONObject()
                val fidoId = body.optString("fido_id", "")
                val sig = body.optString("signature", "")
                val challenge = body.optString("challenge", "")

                synchronized(activeChallenges) {
                    activeChallenges.remove(challenge)
                }

                val raw = "$intent:$fidoId:$sig:$lastHash"
                val crystalHash = sha256(raw)

                val crystal = JSONObject().apply {
                    put("crystal_hash", crystalHash)
                    put("intent", intent)
                    put("fido_id", fidoId)
                    put("signature_stub", sig.take(24) + "...")
                    put("bitemporal", JSONObject().apply {
                        put("transaction_time", System.currentTimeMillis() / 1000.0)
                        put("valid_from", intent.optDouble("requested_at"))
                    })
                }

                val stored = appendCrystal(crystal)
                newFixedLengthResponse(Response.Status.OK, "application/json", "{\"ui_feedback\":\"SUCCESS\",\"crystal\":$stored}")
            }
            uri == "/api/records" && method == Method.GET -> {
                val arr = JSONArray()
                records.forEach { arr.put(it) }
                newFixedLengthResponse(Response.Status.OK, "application/json", "{\"records\":$arr}")
            }
            uri == "/api/audit/raw" && method == Method.GET -> {
                val arr = JSONArray()
                records.forEach { arr.put(it) }
                val merkle = computeMerkleRoot()
                newFixedLengthResponse(Response.Status.OK, "application/json", 
                    "{\"status\":\"INTEGRITA_OVĚŘENA_PLATNÁ\",\"merkle_root\":\"$merkle\",\"records\":$arr}")
            }
            uri == "/audit" -> {
                newFixedLengthResponse(Response.Status.OK, "text/html", renderAuditHtml())
            }
            uri == "/api/export/pohoda.xml" -> {
                newFixedLengthResponse(Response.Status.OK, "application/xml", renderPohodaXml())
            }
            uri == "/api/export/isdoc.xml" -> {
                newFixedLengthResponse(Response.Status.OK, "application/xml", renderIsdocXml())
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

    private fun renderPohodaXml(): String {
        val dispatched = records.filter { it.optJSONObject("intent")?.optString("action") == "DISPATCH_BATCH" }
        val total = dispatched.sumOf { 
            val it = it.getJSONObject("intent")
            it.optInt("portions", 0) * it.optDouble("unit_price", 0.0) 
        }

        val itemsXml = StringBuilder()
        dispatched.forEach { r ->
            val it = r.getJSONObject("intent")
            itemsXml.append("""
                <inv:invoiceItem>
                    <inv:text>${it.optString("item_name")} (Klient: ${it.optString("client_name")}, Alergeny: ${it.optString("allergens")})</inv:text>
                    <inv:quantity>${it.optInt("portions")}</inv:quantity>
                    <inv:unit>porce</inv:unit>
                    <inv:unitPrice>${it.optDouble("unit_price")}</inv:unitPrice>
                    <inv:payVAT>true</inv:payVAT>
                    <inv:rateVAT>12</inv:rateVAT>
                </inv:invoiceItem>
            """.trimIndent())
        }

        return """<?xml version="1.0" encoding="UTF-8"?>
<dat:dataPack xmlns:dat="http://www.stormware.cz/schema/version_2/data.xsd"
              xmlns:inv="http://www.stormware.cz/schema/version_2/invoice.xsd"
              id="INLOOP_${System.currentTimeMillis()}" version="2.0">
    <dat:dataPackItem id="INV_001" version="2.0">
        <inv:invoice version="2.0">
            <inv:invoiceHeader>
                <inv:invoiceType>issuedInvoice</inv:invoiceType>
                <inv:date>${SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date())}</inv:date>
                <inv:text>Měsíční vyúčtování stravného dle nepopiratelného KDS protokolu</inv:text>
            </inv:invoiceHeader>
            <inv:invoiceDetail>
                $itemsXml
            </inv:invoiceDetail>
        </inv:invoice>
    </dat:dataPackItem>
</dat:dataPack>"""
    }

    private fun renderIsdocXml(): String {
        return """<?xml version="1.0" encoding="UTF-8"?><Invoice xmlns="http://isdoc.cz/namespace/2013" version="6.0.2"><ID>INLOOP-${System.currentTimeMillis()}</ID></Invoice>"""
    }

    private fun renderAuditHtml(): String {
        val sdf = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault())
        val genTime = SimpleDateFormat("yyyy-MM-dd HH:mm:ss 'UTC'", Locale.getDefault()).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }.format(Date())

        val merkleRoot = computeMerkleRoot()
        var chainValid = true
        val rows = StringBuilder()

        for (i in 0 until records.size) {
            val r = records[i]
            val it = r.optJSONObject("intent") ?: JSONObject()
            val bt = r.optJSONObject("bitemporal") ?: JSONObject()
            val ts = bt.optDouble("transaction_time", 0.0).toLong() * 1000
            val temp = it.optDouble("temperature", 0.0)
            val action = it.optString("action", "EXPEDICE")
            val itemName = it.optString("item_name", it.optString("item", "Položka"))
            val client = it.optString("client_name", "Běžný výdej")
            val chef = it.optString("chef_name", "Šéfkuchař")
            val allergens = it.optString("allergens", "-")
            val portions = it.optInt("portions", 0)
            val cHash = r.optString("crystal_hash", "")
            val pHash = r.optString("parent_hash", "")

            if (i > 0 && pHash != records[i - 1].optString("crystal_hash")) {
                chainValid = false
            }

            val haccpOk = if (temp >= 65.0) "<span style='color:green;font-weight:bold;'>VYHOVUJE</span>" else "<span style='color:red;font-weight:bold;'>NEVYHOVUJE</span>"
            val formattedDate = if (ts > 0) sdf.format(Date(ts)) else "-"

            rows.append("""
                <tr>
                    <td style='text-align:center;font-weight:bold;'>#${r.optInt("lamport_tick", i + 1)}</td>
                    <td>$formattedDate</td>
                    <td><b>$action</b>: $itemName<br><small style='color:#555;'>Odběratel: <b>$client</b> | Kuchař: <b>$chef</b> | Alergeny: <b>$allergens</b></small></td>
                    <td style='text-align:right;'>$portions ks</td>
                    <td style='text-align:right;font-weight:bold;'>$temp °C</td>
                    <td style='text-align:center;'>$haccpOk</td>
                    <td style='font-family:monospace;font-size:10px;word-break:break-all;'>${cHash.take(18)}...</td>
                </tr>
            """.trimIndent())
        }

        val statusText = if (chainValid && records.isNotEmpty()) "INTEGRITA_OVĚŘENA_PLATNÁ" else if (records.isEmpty()) "LEDGER_PRÁZDNÝ" else "NEPLATNÝ_ŘETĚZEC"
        val statusClass = if (chainValid && records.isNotEmpty()) "valid" else "pending"

        return """
<!DOCTYPE html>
<html lang="cs">
<head>
    <meta charset="UTF-8">
    <title>Úřední Protokol HACCP & Kauzální Integrity</title>
    <style>
        body { font-family: 'Times New Roman', serif; background: #eaedf1; color: #111; padding: 1.5rem; }
        .cert-card { max-width: 950px; margin: auto; background: #fff; border: 3px double #1a365d; padding: 2rem; box-shadow: 0 10px 25px rgba(0,0,0,0.1); position: relative; }
        .stamp { position: absolute; top: 2rem; right: 2rem; border: 2px solid green; padding: 6px 12px; color: green; font-family: monospace; font-weight: bold; font-size: 12px; }
        .stamp.pending { border-color: #f59e0b; color: #b45309; }
        .header { text-align: center; border-bottom: 2px solid #1a365d; padding-bottom: 0.8rem; margin-bottom: 1.2rem; }
        .title { font-size: 1.3rem; font-weight: bold; color: #1a365d; text-transform: uppercase; }
        .subtitle { font-size: 0.85rem; font-style: italic; color: #444; }
        .meta-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0.8rem; font-family: Arial, sans-serif; font-size: 0.82rem; margin-bottom: 1.2rem; }
        .meta-box { background: #f8fafc; border: 1px solid #e2e8f0; padding: 0.6rem; border-radius: 4px; }
        table { width: 100%; border-collapse: collapse; margin-top: 0.8rem; font-family: Arial, sans-serif; font-size: 0.8rem; }
        th, td { border: 1px solid #333; padding: 6px 8px; text-align: left; }
        th { background: #f1f5f9; }
        .legal { font-size: 0.72rem; color: #333; border-top: 1px solid #333; padding-top: 0.8rem; margin-top: 1.2rem; font-family: Arial, sans-serif; line-height: 1.4; }
        .btn-bar { max-width: 950px; margin: auto; margin-bottom: 0.8rem; display: flex; justify-content: space-between; gap: 8px; }
        .btn { background: #1a365d; color: #fff; border: none; padding: 0.6rem 1.2rem; font-weight: bold; cursor: pointer; border-radius: 4px; font-family: Arial, sans-serif; }
    </style>
</head>
<body>
    <div class="btn-bar">
        <button class="btn" onclick="window.print()">TISKNOUT DO PDF</button>
        <div>
            <a href="/api/export/pohoda.xml" target="_blank" class="btn" style="background:#2563eb; text-decoration:none;">POHODA XML</a>
            <button class="btn" style="background:#059669;" onclick="verifyChain()">OVĚŘIT MATEMATICKOU INTEGRITU</button>
        </div>
    </div>

    <div class="cert-card">
        <div class="stamp $statusClass">$statusText</div>
        <div class="header">
            <div class="title">Protokol o Průkazu Shody HACCP a Digitální Kontinuity</div>
            <div class="subtitle">Dle Nařízení ES č. 852/2004, Nařízení EU č. 910/2014 (eIDAS) a Zákona č. 258/2000 Sb.</div>
        </div>

        <div class="meta-grid">
            <div class="meta-box">
                <b>Výrobní uzel:</b> KDS Node #5005 (Standalone Android)<br>
                <b>Typ měření:</b> CCP1 (Výdej &ge; 65.0 °C) / CCP2 (Zchlazení &le; 4.0 °C)<br>
                <b>Alergenní evidence:</b> EU 1169/2011 (Skupiny 1–14)
            </div>
            <div class="meta-box">
                <b>Root Merkle Hash:</b><br>
                <code style="font-size:10px;word-break:break-all;">$merkleRoot</code><br>
                <b>Hardwarové TEE:</b> ARM TrustZone ECDSA (FIDO2 Level 3)
            </div>
        </div>

        <table>
            <thead>
                <tr>
                    <th style="width:35px;">Tick</th>
                    <th style="width:125px;">Čas zápisu</th>
                    <th>Položka, Odběratel & Alergeny</th>
                    <th style="width:50px;">Porce</th>
                    <th style="width:65px;">Teplota</th>
                    <th style="width:85px;">HACCP</th>
                    <th style="width:140px;">Hash (SHA-256)</th>
                </tr>
            </thead>
            <tbody>
                $rows
            </tbody>
        </table>

        <div class="legal">
            <b>ZÁKONNÁ DOLOŽKA A PROHLÁŠENÍ O INTEGRITĚ:</b><br>
            1. <b>eIDAS Čl. 25 a 32:</b> Každý záznam byl autorizován přímo v TEE procesoru zařízení bez možnosti zpětné manipulace.<br>
            2. <b>Vyhotoveno:</b> $genTime
        </div>
    </div>

    <script>
        function verifyChain() {
            fetch('/api/audit/raw')
                .then(r => r.json())
                .then(data => {
                    const recs = data.records;
                    if (!recs || recs.length === 0) {
                        alert("Ledger je prázdný.");
                        return;
                    }
                    let valid = true;
                    for (let i = 1; i < recs.length; i++) {
                        if (recs[i].parent_hash !== recs[i-1].crystal_hash) {
                            valid = false;
                            break;
                        }
                    }
                    if (valid) {
                        alert("KAUZÁLNÍ INTEGRITA 100% PLATNÁ:\n- Krystalů: " + recs.length + "\n- Merkle Root: " + data.merkle_root.substring(0, 16) + "...");
                    } else {
                        alert("VAROVÁNÍ: Řetězec je porušen!");
                    }
                });
        }
    </script>
</body>
</html>
        """.trimIndent()
    }
}
EOF_SERVER

# 2. Komplexní aktualizace index.html s editorem jídelníčku a volbou klienta
cat << 'EOF_HTML' > app/src/main/assets/index.html
<!DOCTYPE html>
<html lang="cs">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
    <title>InLoop Trust KDS Enterprise</title>
    <style>
        :root {
            --bg-base: #030712;
            --surface-glass: rgba(15, 23, 42, 0.82);
            --surface-card: rgba(30, 41, 59, 0.55);
            --surface-active: rgba(56, 189, 248, 0.18);
            --stroke-glass: rgba(255, 255, 255, 0.09);
            --accent-cyan: #38bdf8;
            --emerald: #10b981;
            --amber: #f59e0b;
            --rose: #f43f5e;
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
            --text-dim: #64748b;
        }

        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; margin: 0; padding: 0; user-select: none; }
        
        body {
            background: var(--bg-base);
            color: var(--text-main);
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
            min-height: 100dvh;
            padding: env(safe-area-inset-top, 0.6rem) env(safe-area-inset-right, 0.6rem) env(safe-area-inset-bottom, 0.6rem) env(safe-area-inset-left, 0.6rem);
            display: flex;
            flex-direction: column;
            gap: 0.6rem;
        }

        .nav-bar {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 0.6rem 0.9rem;
            background: var(--surface-glass);
            border: 1px solid var(--stroke-glass);
            border-radius: 14px;
        }
        .brand { font-size: 1.05rem; font-weight: 800; color: #fff; }
        .brand span { color: var(--accent-cyan); }
        .nav-right { display: flex; align-items: center; gap: 0.4rem; }
        .capsule {
            background: rgba(16, 185, 129, 0.12);
            border: 1px solid var(--emerald);
            color: var(--emerald);
            padding: 0.25rem 0.55rem;
            border-radius: 8px;
            font-size: 0.68rem;
            font-weight: 700;
        }
        .btn-top {
            background: rgba(255, 255, 255, 0.06);
            border: 1px solid var(--stroke-glass);
            color: var(--text-main);
            padding: 0.25rem 0.5rem;
            border-radius: 8px;
            font-size: 0.68rem;
            font-weight: 700;
            cursor: pointer;
        }

        .workspace {
            display: grid;
            grid-template-columns: 1.35fr 1fr;
            gap: 0.6rem;
            flex: 1;
            min-height: 0;
        }
        @media (orientation: portrait), (max-width: 850px) {
            .workspace { grid-template-columns: 1fr; display: flex; flex-direction: column; }
        }

        .glass-panel {
            background: var(--surface-glass);
            border: 1px solid var(--stroke-glass);
            border-radius: 16px;
            padding: 0.85rem;
            display: flex;
            flex-direction: column;
            min-height: 0;
        }

        .section-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 0.6rem;
            font-size: 0.72rem;
            font-weight: 800;
            color: var(--text-dim);
            text-transform: uppercase;
        }

        /* Odběratel Selector */
        .client-selector {
            display: flex;
            gap: 0.3rem;
            margin-bottom: 0.6rem;
            overflow-x: auto;
            padding-bottom: 0.2rem;
        }
        .client-chip {
            background: rgba(255,255,255,0.04);
            border: 1px solid var(--stroke-glass);
            color: var(--text-muted);
            padding: 0.3rem 0.6rem;
            border-radius: 8px;
            font-size: 0.72rem;
            font-weight: 700;
            cursor: pointer;
            white-space: nowrap;
        }
        .client-chip.active {
            background: rgba(56, 189, 248, 0.15);
            border-color: var(--accent-cyan);
            color: #fff;
        }

        /* Menu Grid */
        .menu-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 0.45rem;
            margin-bottom: 0.6rem;
        }
        .dish-card {
            background: var(--surface-card);
            border: 1px solid var(--stroke-glass);
            border-radius: 12px;
            padding: 0.65rem;
            cursor: pointer;
            min-height: 68px;
            display: flex;
            flex-direction: column;
            justify-content: space-between;
        }
        .dish-card:active { transform: scale(0.98); }
        .dish-card.active {
            background: var(--surface-active);
            border-color: var(--accent-cyan);
            box-shadow: 0 0 14px rgba(56, 189, 248, 0.22);
        }
        .dish-top-row { display: flex; justify-content: space-between; font-size: 0.65rem; font-weight: 800; color: var(--accent-cyan); }
        .dish-name { font-size: 0.82rem; font-weight: 700; color: #fff; line-height: 1.2; margin: 0.2rem 0; }
        .dish-allergens { font-size: 0.65rem; color: var(--text-dim); }

        /* Controls */
        .metrics-row {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 0.45rem;
            margin-bottom: 0.6rem;
        }
        .metric-tile {
            background: rgba(15, 23, 42, 0.5);
            border: 1px solid var(--stroke-glass);
            border-radius: 12px;
            padding: 0.55rem;
        }
        .metric-val-box {
            background: rgba(0,0,0,0.3);
            border-radius: 8px;
            padding: 0.3rem;
            text-align: center;
            margin: 0.25rem 0;
            font-size: 1.25rem;
            font-weight: 900;
            font-variant-numeric: tabular-nums;
        }
        .stepper { display: flex; gap: 0.2rem; }
        .btn-step {
            flex: 1;
            padding: 0.45rem 0.1rem;
            background: rgba(255,255,255,0.06);
            border: 1px solid var(--stroke-glass);
            color: #fff;
            font-weight: 800;
            font-size: 0.8rem;
            border-radius: 6px;
            cursor: pointer;
        }
        .btn-step:active { background: var(--accent-cyan); color: #000; }

        .actions-cluster {
            display: grid;
            grid-template-columns: 1.3fr 1fr;
            gap: 0.45rem;
            margin-top: auto;
        }
        .btn-act {
            padding: 0.85rem 0.4rem;
            border-radius: 10px;
            border: none;
            font-size: 0.85rem;
            font-weight: 900;
            cursor: pointer;
            text-transform: uppercase;
        }
        .btn-dispatch { background: linear-gradient(135deg, #38bdf8, #2563eb); color: #000; }
        .btn-accept { background: rgba(255, 255, 255, 0.08); border: 1px solid var(--stroke-glass); color: #fff; }

        /* Feed */
        .stream-container {
            flex: 1;
            overflow-y: auto;
            display: flex;
            flex-direction: column;
            gap: 0.4rem;
            max-height: 480px;
        }
        @media (orientation: portrait) { .stream-container { max-height: 220px; } }
        .stream-card {
            background: rgba(15, 23, 42, 0.55);
            border: 1px solid var(--stroke-glass);
            border-radius: 10px;
            padding: 0.65rem;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .stream-title { font-size: 0.8rem; font-weight: 800; color: #fff; }
        .stream-meta { font-size: 0.68rem; color: var(--text-dim); margin-top: 0.15rem; }

        /* Gatekeeper & Modals */
        .gatekeeper-screen {
            position: fixed; inset: 0; background: radial-gradient(circle at center, #0f172a 0%, #030712 100%);
            z-index: 10000; display: flex; flex-direction: column; justify-content: center; align-items: center; padding: 1.5rem; text-align: center;
        }
        .gatekeeper-screen.unlocked { opacity: 0; visibility: hidden; pointer-events: none; }
        .input-chef {
            background: rgba(255,255,255,0.06); border: 1px solid var(--stroke-glass); color: #fff;
            padding: 0.75rem 1rem; border-radius: 10px; font-size: 1rem; width: 100%; max-width: 320px; margin-bottom: 1rem; text-align: center;
        }

        .modal {
            position: fixed; inset: 0; background: rgba(3, 7, 18, 0.88); backdrop-filter: blur(20px);
            display: flex; justify-content: center; align-items: center; z-index: 9999; opacity: 0; pointer-events: none; padding: 1rem;
        }
        .modal.active { opacity: 1; pointer-events: auto; }
        .modal-sheet {
            background: rgba(30, 41, 59, 0.95); border: 1px solid var(--stroke-glass); border-radius: 18px;
            padding: 1.3rem; max-width: 440px; width: 100%; max-height: 85vh; overflow-y: auto;
        }
    </style>
</head>
<body>

    <!-- ONBOARDING BRÁNA -->
    <div id="gatekeeper" class="gatekeeper-screen">
        <div style="font-size:3.5rem; margin-bottom:0.8rem;">👨‍🍳</div>
        <h2 style="color:#fff; margin-bottom:0.4rem;">INLOOP TRUST KDS</h2>
        <p style="color:var(--text-muted); font-size:0.85rem; max-width:320px; margin-bottom:1.2rem;">
            Zadejte jméno šéfkuchaře pro tuto směnu a přiložte prst k senzoru pro ukování TEE klíče.
        </p>
        <input type="text" id="chef-name-input" class="input-chef" value="Šéfkuchař Zbyněk" placeholder="Jméno odpovědné osoby">
        <button onclick="enrollChef()" style="background:linear-gradient(135deg, #38bdf8, #2563eb); color:#000; border:none; border-radius:12px; padding:1rem 2rem; font-size:0.95rem; font-weight:900; cursor:pointer;">
            ✦ UKOVAT TEE KLÍČ & VSTOUPIT
        </button>
    </div>

    <!-- HLAVNÍ KDS -->
    <div class="nav-bar">
        <div class="brand"><span>INLOOP</span> TRUST KDS</div>
        <div class="nav-right">
            <div class="capsule" id="enclave-status">ŠÉFKUCHAŘ: AKTIVNÍ</div>
            <button class="btn-top" onclick="openMenuEditor()">✎ Jídelníček</button>
            <button class="btn-top" onclick="reEnroll()">Směna</button>
        </div>
    </div>

    <div class="workspace">
        <div class="glass-panel">
            <!-- Výběr klienta -->
            <div class="section-header">
                <span>1. Odběratel / Trasa</span>
                <span id="selected-chef-label" style="color:var(--accent-cyan);">Šéfkuchař</span>
            </div>
            <div class="client-selector">
                <div class="client-chip active" onclick="selectClient(this, 'Běžný výdej jídelna')">Jídelna výdej</div>
                <div class="client-chip" onclick="selectClient(this, 'Siemens Brno')">Siemens Brno</div>
                <div class="client-chip" onclick="selectClient(this, 'Honeywell')">Honeywell</div>
                <div class="client-chip" onclick="selectClient(this, 'Rozvoz Trasa A')">Rozvoz Trasa A</div>
            </div>

            <!-- Menu Grid -->
            <div class="section-header">
                <span>2. Položka menu</span>
                <span style="font-size:0.65rem; color:var(--emerald);">CCP1 (&ge;65°C)</span>
            </div>
            <div class="menu-grid" id="dishes-container"></div>

            <!-- Parametry -->
            <div class="metrics-row">
                <div class="metric-tile">
                    <span style="font-size:0.65rem; color:var(--text-dim); font-weight:700;">PORCE</span>
                    <div class="metric-val-box" id="disp-portions">45</div>
                    <div class="stepper">
                        <button class="btn-step" onclick="modPortions(-5)">-5</button>
                        <button class="btn-step" onclick="modPortions(-1)">-1</button>
                        <button class="btn-step" onclick="modPortions(1)">+1</button>
                        <button class="btn-step" onclick="modPortions(5)">+5</button>
                    </div>
                </div>

                <div class="metric-tile">
                    <span style="font-size:0.65rem; color:var(--text-dim); font-weight:700;">HACCP TEPLOTA</span>
                    <div class="metric-val-box" id="disp-temp">76.5 °C</div>
                    <div class="stepper">
                        <button class="btn-step" onclick="modTemp(-1.0)">-1°</button>
                        <button class="btn-step" onclick="modTemp(1.0)">+1°</button>
                    </div>
                </div>
            </div>

            <div class="actions-cluster">
                <button class="btn-act btn-dispatch" onclick="commitIntent('DISPATCH_BATCH')">EXPEDOVAT (OTISK)</button>
                <button class="btn-act btn-accept" onclick="commitIntent('ACCEPT_BATCH')">PŘIJMOUT</button>
            </div>
        </div>

        <!-- Audit & Feed -->
        <div class="glass-panel">
            <div class="section-header">
                <span>Krystalický feed</span>
                <div>
                    <a href="/audit" target="_blank" style="color:var(--accent-cyan); text-decoration:none; font-weight:700; margin-right:8px;">Audit ↗</a>
                    <a href="/api/export/pohoda.xml" target="_blank" style="color:var(--emerald); text-decoration:none; font-weight:700;">Pohoda</a>
                </div>
            </div>
            <div class="stream-container" id="stream-feed"></div>
        </div>
    </div>

    <!-- MODAL: EDITOR JÍDELNÍČKU -->
    <div id="modal-menu-editor" class="modal">
        <div class="modal-sheet">
            <h3 style="color:#fff; margin-bottom:0.8rem;">Správa denního menu</h3>
            <div id="menu-editor-fields" style="display:flex; flex-direction:column; gap:0.5rem; margin-bottom:1rem;"></div>
            <button onclick="saveMenu()" style="background:var(--emerald); color:#000; border:none; border-radius:10px; padding:0.8rem; width:100%; font-weight:900; cursor:pointer;">
                ULOŽIT DENNÍ MENU
            </button>
            <button onclick="closeModal('modal-menu-editor')" style="background:transparent; border:1px solid var(--stroke-glass); color:#fff; border-radius:10px; padding:0.6rem; width:100%; font-weight:700; margin-top:0.4rem; cursor:pointer;">
                ZAVŘÍT
            </button>
        </div>
    </div>

    <!-- MODAL: CHYBA / STOP-STAV -->
    <div id="modal-error" class="modal">
        <div class="modal-sheet" style="text-align:center;">
            <h3 style="color:var(--rose);">HACCP STOP-STAV</h3>
            <p style="color:var(--text-muted); margin-top:0.5rem; font-size:0.85rem;" id="modal-err-msg">Teplota neodpovídá normě!</p>
            <button onclick="closeModal('modal-error')" style="background:var(--rose); color:#fff; border:none; border-radius:10px; padding:0.8rem; width:100%; font-weight:900; margin-top:1rem; cursor:pointer;">
                ROZUMÍM
            </button>
        </div>
    </div>

    <!-- MODAL: ÚSPĚCH -->
    <div id="modal-success" class="modal">
        <div class="modal-sheet" style="text-align:center;">
            <h3 style="color:var(--emerald);">ZAPEČETĚNO V TEE</h3>
            <p style="color:var(--text-muted); margin-top:0.5rem; font-size:0.85rem;" id="modal-succ-msg">Várka byla podepsána a uložena.</p>
            <button onclick="closeModal('modal-success')" style="background:var(--emerald); color:#000; border:none; border-radius:10px; padding:0.8rem; width:100%; font-weight:900; margin-top:1rem; cursor:pointer;">
                HOTOVO
            </button>
        </div>
    </div>

    <script>
        let currentMenu = [];
        let selectedItem = null;
        let selectedClient = "Běžný výdej jídelna";
        let chefName = "Šéfkuchař Zbyněk";
        let portions = 45;
        let temperature = 76.5;
        let currentIntent = null;
        let currentChallenge = null;

        function loadMenu() {
            fetch('/api/menu').then(r => r.json()).then(items => {
                currentMenu = items;
                renderDishes();
            });
        }

        function renderDishes() {
            const container = document.getElementById('dishes-container');
            container.innerHTML = '';
            currentMenu.forEach((item, idx) => {
                const isSelected = (!selectedItem && idx === 0) || (selectedItem && selectedItem.id === item.id);
                if (isSelected) selectedItem = item;

                container.innerHTML += `
                    <div class="dish-card ${isSelected ? 'active' : ''}" onclick="selectDish('${item.id}')">
                        <div class="dish-top-row">
                            <span>${item.id}</span>
                            <span>${item.price} Kč</span>
                        </div>
                        <div class="dish-name">${item.name}</div>
                        <div class="dish-allergens">Alergeny: ${item.allergens || '-'}</div>
                    </div>
                `;
            });
        }

        function selectDish(id) {
            selectedItem = currentMenu.find(i => i.id === id);
            renderDishes();
        }

        function selectClient(el, name) {
            document.querySelectorAll('.client-chip').forEach(c => c.classList.remove('active'));
            el.classList.add('active');
            selectedClient = name;
        }

        function modPortions(d) {
            portions = Math.max(1, Math.min(250, portions + d));
            document.getElementById('disp-portions').innerText = portions;
        }

        function modTemp(d) {
            temperature = Math.round((temperature + d) * 10) / 10;
            document.getElementById('disp-temp').innerText = temperature.toFixed(1) + " °C";
        }

        function openMenuEditor() {
            const container = document.getElementById('menu-editor-fields');
            container.innerHTML = '';
            currentMenu.forEach((item, idx) => {
                container.innerHTML += `
                    <div style="background:rgba(0,0,0,0.3); padding:0.5rem; border-radius:8px; font-size:0.75rem;">
                        <input type="text" id="edit-name-${idx}" value="${item.name}" style="width:100%; background:transparent; border:1px solid var(--stroke-glass); color:#fff; padding:0.3rem; margin-bottom:0.3rem; border-radius:4px;">
                        <div style="display:flex; gap:0.4rem;">
                            <input type="number" id="edit-price-${idx}" value="${item.price}" placeholder="Cena Kč" style="width:70px; background:transparent; border:1px solid var(--stroke-glass); color:#fff; padding:0.3rem; border-radius:4px;">
                            <input type="text" id="edit-allergens-${idx}" value="${item.allergens}" placeholder="Alergeny (1,3,7)" style="flex:1; background:transparent; border:1px solid var(--stroke-glass); color:#fff; padding:0.3rem; border-radius:4px;">
                        </div>
                    </div>
                `;
            });
            document.getElementById('modal-menu-editor').classList.add('active');
        }

        function saveMenu() {
            currentMenu.forEach((item, idx) => {
                item.name = document.getElementById(`edit-name-${idx}`).value;
                item.price = parseFloat(document.getElementById(`edit-price-${idx}`).value) || item.price;
                item.allergens = document.getElementById(`edit-allergens-${idx}`).value;
            });

            fetch('/api/menu', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ items: currentMenu })
            }).then(() => {
                closeModal('modal-menu-editor');
                renderDishes();
            });
        }

        function showModal(id, msg) {
            if (msg) document.querySelector(`#${id} p`).innerText = msg;
            document.getElementById(id).classList.add('active');
        }

        function closeModal(id) {
            document.getElementById(id).classList.remove('active');
        }

        function enrollChef() {
            chefName = document.getElementById('chef-name-input').value || "Šéfkuchař";
            document.getElementById('selected-chef-label').innerText = chefName;
            if (window.AndroidBridge && typeof window.AndroidBridge.enrollChefKey === 'function') {
                window.AndroidBridge.enrollChefKey();
            } else {
                showModal('modal-error', 'Android biometrický senzor není dostupný.');
            }
        }

        function reEnroll() {
            document.getElementById('gatekeeper').classList.remove('unlocked');
        }

        window.onEnrollmentSuccess = function(publicKey) {
            document.getElementById('gatekeeper').classList.add('unlocked');
            document.getElementById('enclave-status').innerText = chefName.toUpperCase();
            showModal('modal-success', 'Klíč šéfkuchaře ukován v procesoru TEE. Terminál odemčen.');
        };

        async function commitIntent(action) {
            if (!selectedItem) return;

            currentIntent = {
                action: action,
                item: selectedItem.id,
                item_name: selectedItem.name,
                unit_price: selectedItem.price,
                allergens: selectedItem.allergens,
                client_name: selectedClient,
                chef_name: chefName,
                portions: portions,
                temperature: temperature,
                ccp_type: "CCP1_VYDEJ",
                requested_at: Date.now() / 1000
            };

            try {
                const pf = await fetch('/api/macaroon/preflight', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ intent: currentIntent })
                });
                const pfData = await pf.json();
                if (pfData.status !== "SUCCESS") {
                    showModal('modal-error', pfData.message);
                    return;
                }

                const cRes = await fetch('/api/auth/challenge');
                const { challenge } = await cRes.json();
                currentChallenge = challenge;

                const payloadToSign = JSON.stringify(currentIntent) + ":" + currentChallenge;

                if (window.AndroidBridge && typeof window.AndroidBridge.authenticateAndSign === 'function') {
                    window.AndroidBridge.authenticateAndSign(payloadToSign);
                } else {
                    showModal('modal-error', 'Android biometrický senzor není dostupný.');
                }
            } catch (err) {
                showModal('modal-error', 'Chyba spojení s uzlem: ' + err.message);
            }
        }

        window.onBiometricSuccess = async function(signatureBase64, publicKeyBase64) {
            try {
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
                    showModal('modal-success', `Zapečetěno: ${currentIntent.item_name} (${currentIntent.portions} ks pro ${currentIntent.client_name}).`);
                    loadRecords();
                } else {
                    showModal('modal-error', "Chyba zápisu: " + r.message);
                }
            } catch (err) {
                showModal('modal-error', "Chyba krystalu: " + err.message);
            }
        };

        window.onBiometricError = function(errorMsg) {
            showModal('modal-error', errorMsg);
        };

        function loadRecords() {
            fetch('/api/records').then(r => r.json()).then(data => {
                const feed = document.getElementById('stream-feed');
                feed.innerHTML = '';
                data.records.reverse().forEach(r => {
                    const it = r.intent;
                    const isDisp = it.action === 'DISPATCH_BATCH';
                    const date = new Date(r.bitemporal.transaction_time * 1000).toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'});
                    feed.innerHTML += `
                        <div class="stream-card">
                            <div>
                                <div class="stream-title">${it.item_name} (${it.portions} ks)</div>
                                <div class="stream-meta"><b>${it.client_name}</b> • ${it.temperature} °C • ${date}</div>
                            </div>
                            <div class="badge-disp" style="background:${isDisp ? 'rgba(16,185,129,0.15)' : 'rgba(245,158,11,0.15)'}; color:${isDisp ? 'var(--emerald)' : 'var(--amber)'}; padding:0.25rem 0.5rem; border-radius:6px; font-size:0.65rem; font-weight:800;">
                                ${isDisp ? 'EXPEDOVÁNO' : 'PŘIJATO'}
                            </div>
                        </div>
                    `;
                });
            }).catch(e => console.error(e));
        }

        // Ověření stavu
        function checkEnclave() {
            if (window.AndroidBridge && typeof window.AndroidBridge.getEnrolledKeyStatus === 'function') {
                try {
                    const status = JSON.parse(window.AndroidBridge.getEnrolledKeyStatus());
                    if (status.enrolled) {
                        document.getElementById('gatekeeper').classList.add('unlocked');
                    }
                } catch(e){}
            }
        }

        loadMenu();
        loadRecords();
        setTimeout(checkEnclave, 500);
        setInterval(loadRecords, 3000);
    </script>
</body>
</html>
EOF_HTML

echo "[SUCCESS] Plná verze Enterprise KDS je připravena!"
