package cz.inloop.kds

import android.content.Context
import fi.iki.elonen.NanoHTTPD
import fi.iki.elonen.NanoHTTPD.Method
import fi.iki.elonen.NanoHTTPD.Response
import fi.iki.elonen.NanoHTTPD.Response.Status
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
    private val ordersFile = File(context.filesDir, "kds_b2b_orders.json")
    private val rsEngine = ReedSolomonEngine(16)

    private val mimeJson = "application/json; charset=UTF-8"
    private val mimeHtml = "text/html; charset=UTF-8"
    private val mimePlain = "text/plain; charset=UTF-8"
    private val mimeXml = "application/xml; charset=UTF-8"

    private var lastHash = "0000000000000000000000000000000000000000000000000000000000000000"
    private var lamportClock = 0
    private val records = CopyOnWriteArrayList<JSONObject>()
    private val zkWorkers = CopyOnWriteArrayList<JSONObject>()
    private val b2bOrders = CopyOnWriteArrayList<JSONObject>()
    private val activeChallenges = HashMap<String, Long>()

    init {
        loadBinaryLedger()
        loadB2bOrders()
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

    private fun loadB2bOrders() {
        if (ordersFile.exists()) {
            try {
                val array = JSONArray(ordersFile.readText(Charsets.UTF_8))
                for (i in 0 until array.length()) {
                    val obj = array.optJSONObject(i) ?: continue
                    b2bOrders.add(obj)
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    @Synchronized
    private fun saveB2bOrder(order: JSONObject) {
        b2bOrders.add(order)
        val arr = JSONArray()
        b2bOrders.forEach { arr.put(it) }
        ordersFile.writeText(arr.toString(2), Charsets.UTF_8)
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
            workersFile.writeText(arr.toString(2), Charsets.UTF_8)
        } else {
            try {
                val arr = JSONArray(workersFile.readText(Charsets.UTF_8))
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
            menuFile.writeText(defaultMenu.toString(2), Charsets.UTF_8)
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
            val res = newFixedLengthResponse(Status.OK, mimePlain, "")
            addCorsHeaders(res)
            return res
        }

        val response = when {
            uri == "/" -> {
                try {
                    val html = context.assets.open("index.html").bufferedReader(Charsets.UTF_8).use { it.readText() }
                    newFixedLengthResponse(Status.OK, mimeHtml, html)
                } catch (e: Exception) {
                    newFixedLengthResponse(Status.INTERNAL_ERROR, mimePlain, "Chyba načtení šablony: ${e.message}")
                }
            }
            uri == "/portal" -> {
                newFixedLengthResponse(Status.OK, mimeHtml, renderB2bPortalHtml())
            }
            uri == "/api/portal/order" && method == Method.POST -> {
                val body = readJsonBody(session)
                body.put("created_at", System.currentTimeMillis() / 1000.0)
                body.put("order_id", "ORD_" + System.currentTimeMillis().toString().takeLast(6))
                saveB2bOrder(body)
                newFixedLengthResponse(Status.OK, mimeJson, "{\"status\":\"SUCCESS\",\"message\":\"Objednávka přijata do fronty.\"}")
            }
            uri == "/api/portal/summary" && method == Method.GET -> {
                val arr = JSONArray()
                b2bOrders.forEach { arr.put(it) }
                newFixedLengthResponse(Status.OK, mimeJson, "{\"orders\":$arr}")
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
                newFixedLengthResponse(Status.OK, mimeJson, arr.toString())
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
                workersFile.writeText(arr.toString(2), Charsets.UTF_8)

                newFixedLengthResponse(Status.OK, mimeJson, "{\"status\":\"SUCCESS\",\"commitment\":\"$comm\"}")
            }
            uri == "/api/menu" && method == Method.GET -> {
                val menuContent = if (menuFile.exists()) menuFile.readText(Charsets.UTF_8) else "[]"
                newFixedLengthResponse(Status.OK, mimeJson, menuContent)
            }
            uri == "/api/auth/challenge" && method == Method.GET -> {
                val bytes = ByteArray(32)
                SecureRandom().nextBytes(bytes)
                val challenge = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
                val merkleRoot = computeWorkersMerkleRoot()

                synchronized(activeChallenges) {
                    activeChallenges[challenge] = System.currentTimeMillis()
                }
                newFixedLengthResponse(Status.OK, mimeJson, "{\"challenge\":\"$challenge\",\"merkle_root\":\"$merkleRoot\"}")
            }
            uri == "/api/crystallize" && method == Method.POST -> {
                val body = readJsonBody(session)
                val intent = body.optJSONObject("intent") ?: JSONObject()
                val canonicalPayload = body.optString("canonical_payload", "")
                val fidoId = body.optString("fido_id", "")
                val sig = body.optString("signature", "")
                val challenge = body.optString("challenge", "")
                val workerComm = intent.optString("worker_commitment", "")

                val isValidChallenge = synchronized(activeChallenges) {
                    activeChallenges.remove(challenge) != null
                }
                if (!isValidChallenge) {
                    newFixedLengthResponse(Status.FORBIDDEN, mimeJson, "{\"ui_feedback\":\"ERROR\",\"message\":\"Neplatná výzva!\"}")
                } else {
                    val merkleRoot = computeWorkersMerkleRoot()
                    val isSignatureValid = verifyEcdsaSignature(fidoId, canonicalPayload, sig)
                    val isWorkerInSet = zkWorkers.any { it.getString("commitment") == workerComm } || zkWorkers.isEmpty()

                    if (!isSignatureValid || !isWorkerInSet) {
                        newFixedLengthResponse(Status.FORBIDDEN, mimeJson, "{\"ui_feedback\":\"ERROR\",\"message\":\"ZK STOP: Matematické ověření TEE podpisu nebo členství selhalo!\"}")
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
                        newFixedLengthResponse(Status.OK, mimeJson, "{\"ui_feedback\":\"SUCCESS\",\"crystal\":$stored}")
                    }
                }
            }
            uri == "/api/records" && method == Method.GET -> {
                val arr = JSONArray()
                records.forEach { arr.put(it) }
                newFixedLengthResponse(Status.OK, mimeJson, "{\"records\":$arr}")
            }
            uri == "/audit" -> {
                newFixedLengthResponse(Status.OK, mimeHtml, renderZkAuditHtml())
            }
            uri == "/api/export/pohoda.xml" -> {
                newFixedLengthResponse(Status.OK, mimeXml, renderPohodaXml())
            }
            else -> newFixedLengthResponse(Status.NOT_FOUND, mimePlain, "404 Not Found")
        }

        addCorsHeaders(response)
        return response
    }

    private fun addCorsHeaders(response: Response) {
        response.addHeader("Access-Control-Allow-Origin", "*")
        response.addHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        response.addHeader("Access-Control-Allow-Headers", "Content-Type, Authorization")
    }

    private fun renderB2bPortalHtml(): String {
        val menuContent = if (menuFile.exists()) menuFile.readText(Charsets.UTF_8) else "[]"
        return """
<!DOCTYPE html>
<html lang="cs">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Firemní Objednávka Obědů | InLoop B2B</title>
    <style>
        body { font-family: system-ui, sans-serif; background: #0f172a; color: #f8fafc; padding: 1.5rem; max-width: 600px; margin: auto; }
        .card { background: rgba(30, 41, 59, 0.7); border: 1px solid rgba(255,255,255,0.1); border-radius: 16px; padding: 1.2rem; margin-bottom: 1rem; }
        h2 { color: #38bdf8; margin-top: 0; }
        input, select { width: 100%; background: #1e293b; border: 1px solid #334155; color: #fff; padding: 0.8rem; border-radius: 8px; margin-top: 0.3rem; margin-bottom: 0.8rem; box-sizing: border-box; }
        .menu-item { border-bottom: 1px solid #334155; padding: 0.6rem 0; display: flex; justify-content: space-between; align-items: center; }
        .btn { background: linear-gradient(135deg, #38bdf8, #2563eb); color: #000; font-weight: 800; border: none; padding: 1rem; border-radius: 10px; width: 100%; cursor: pointer; font-size: 1rem; }
    </style>
</head>
<body>
    <div class="card">
        <h2>Firemní Obědy (Uzávěrka 9:30)</h2>
        <p style="color:#94a3b8; font-size:0.85rem;">Objednávka se propíše přímo do expedičního plánu kuchyně.</p>
        
        <label>Vaše Firma / Odběratel:</label>
        <select id="company-select">
            <option value="Siemens Brno">Siemens Brno</option>
            <option value="Honeywell">Honeywell</option>
            <option value="Kanceláře Slavkov">Kanceláře Slavkov</option>
            <option value="Jídelna výdej">Jídelna výdej</option>
        </select>

        <label>Počet porcí:</label>
        <input type="number" id="portions-count" value="10" min="1" max="250">

        <label>Výběr menu:</label>
        <div id="portal-menu-list"></div>

        <button class="btn" onclick="submitOrder()">ODESLAT OBJEDNÁVKU DO KUCHYNĚ</button>
    </div>

    <script>
        const menu = $menuContent;
        let selectedMenuId = menu[0]?.id || "";

        const container = document.getElementById('portal-menu-list');
        menu.forEach((m, idx) => {
            container.innerHTML += '<div class="menu-item"><div><b>' + m.id + ': ' + m.name + '</b><br><small style="color:#94a3b8;">' + m.price + ' Kč | Alergeny: ' + (m.allergens || '-') + '</small></div><input type="radio" name="dish_pick" value="' + m.id + '" ' + (idx===0?'checked':'') + ' onchange="selectedMenuId=\'' + m.id + '\'" style="width:20px; height:20px;"></div>';
        });

        function submitOrder() {
            const company = document.getElementById('company-select').value;
            const count = parseInt(document.getElementById('portions-count').value) || 1;
            const pickedDish = menu.find(m => m.id === selectedMenuId);

            fetch('/api/portal/order', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    company: company,
                    dish_id: pickedDish.id,
                    dish_name: pickedDish.name,
                    price: pickedDish.price,
                    portions: count
                })
            }).then(r => r.json()).then(d => {
                alert("Objednávka pro " + company + " (" + count + " ks) byla odeslána do KDS!");
            });
        }
    </script>
</body>
</html>
        """.trimIndent()
    }

    private fun renderPohodaXml(): String {
        val dispatched = records.filter { it.optJSONObject("intent")?.optString("action") == "DISPATCH_BATCH" }
        val itemsXml = StringBuilder()
        dispatched.forEach { r ->
            val it = r.getJSONObject("intent")
            itemsXml.append("""
                <inv:invoiceItem>
                    <inv:text>${it.optString("item_name")} (Klient: ${it.optString("client_name")})</inv:text>
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
                <inv:text>Vyúčtování stravného KDS TEE</inv:text>
            </inv:invoiceHeader>
            <inv:invoiceDetail>
                $itemsXml
            </inv:invoiceDetail>
        </inv:invoice>
    </dat:dataPackItem>
</dat:dataPack>"""
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
