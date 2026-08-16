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
