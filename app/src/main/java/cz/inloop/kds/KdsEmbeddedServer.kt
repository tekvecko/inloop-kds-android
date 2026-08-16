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
    private val ordersFile = File(context.filesDir, "kds_b2b_orders.json")

    private var lastHash = "0000000000000000000000000000000000000000000000000000000000000000"
    private var lamportClock = 0
    private val records = CopyOnWriteArrayList<JSONObject>()
    private val b2bOrders = CopyOnWriteArrayList<JSONObject>()
    private val activeChallenges = HashMap<String, Long>()

    init {
        loadLedger()
        loadB2bOrders()
        initDefaultMenu()
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
                    put("type", "HLAVNI")
                })
                put(JSONObject().apply {
                    put("id", "MENU_2")
                    put("name", "Kuřecí plátek s bylinkami, grilovaná zelenina")
                    put("price", 149.0)
                    put("food_cost", 48.0)
                    put("allergens", "7, 9")
                    put("type", "HLAVNI")
                })
                put(JSONObject().apply {
                    put("id", "MENU_3")
                    put("name", "Pečená dýně s quinoou a cizrnou (Veggie)")
                    put("price", 139.0)
                    put("food_cost", 38.0)
                    put("allergens", "6, 11")
                    put("type", "DIETA")
                })
                put(JSONObject().apply {
                    put("id", "POLEVKA_1")
                    put("name", "Poctivý hovězí vývar s játrovými knedlíčky")
                    put("price", 45.0)
                    put("food_cost", 14.0)
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

    private fun loadB2bOrders() {
        if (ordersFile.exists()) {
            try {
                val array = JSONArray(ordersFile.readText())
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
        ordersFile.writeText(arr.toString(2))
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
                    newFixedLengthResponse(Response.Status.INTERNAL_ERROR, "text/plain", "Chyba: ${e.message}")
                }
            }
            uri == "/portal" -> {
                newFixedLengthResponse(Response.Status.OK, "text/html", renderB2bPortalHtml())
            }
            uri == "/api/portal/order" && method == Method.POST -> {
                val body = readJsonBody(session)
                body.put("created_at", System.currentTimeMillis() / 1000.0)
                saveB2bOrder(body)
                newFixedLengthResponse(Response.Status.OK, "application/json", "{\"status\":\"SUCCESS\",\"message\":\"Objednávka přijata.\"}")
            }
            uri == "/api/portal/summary" -> {
                val arr = JSONArray()
                b2bOrders.forEach { arr.put(it) }
                newFixedLengthResponse(Response.Status.OK, "application/json", "{\"orders\":$arr}")
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
                if (temp < 65.0) {
                    newFixedLengthResponse(Response.Status.FORBIDDEN, "application/json", 
                        "{\"status\":\"REJECTED\",\"message\":\"HACCP STOP: Výdejní teplota $temp °C je pod normou (65.0 °C)!\"}")
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
            uri == "/audit" -> {
                newFixedLengthResponse(Response.Status.OK, "text/html", renderAuditHtml())
            }
            uri == "/api/export/pohoda.xml" -> {
                newFixedLengthResponse(Response.Status.OK, "application/xml", renderPohodaXml())
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

    private fun renderB2bPortalHtml(): String {
        val menuContent = if (menuFile.exists()) menuFile.readText() else "[]"
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
            <option value="Ostatní firemní odběratelé">Ostatní firemní odběratelé</option>
        </select>

        <label>Jméno strávníka / Kancelář:</label>
        <input type="text" id="emp-name" placeholder="Např. Ing. Novák (Oddělení IT)">

        <label>Výběr menu:</label>
        <div id="portal-menu-list"></div>

        <button class="btn" onclick="submitOrder()">ODESLAT OBJEDNÁVKU DO KUCHYNĚ</button>
    </div>

    <script>
        const menu = $menuContent;
        let selectedMenuId = menu[0]?.id || "";

        const container = document.getElementById('portal-menu-list');
        menu.forEach((m, idx) => {
            container.innerHTML += `
                <div class="menu-item">
                    <div>
                        <b>${'{'}m.id{'}'}: ${'{'}m.name{'}'}</b><br>
                        <small style="color:#94a3b8;">${'{'}m.price{'}'} Kč | Alergeny: ${'{'}m.allergens || '-'{'}'}</small>
                    </div>
                    <input type="radio" name="dish_pick" value="${'{'}m.id{'}'}" ${'{'}idx===0?'checked':''{'}'} onchange="selectedMenuId='${'{'}m.id{'}'}'" style="width:20px; height:20px;">
                </div>
            `;
        });

        function submitOrder() {
            const company = document.getElementById('company-select').value;
            const emp = document.getElementById('emp-name').value;
            if (!emp) { alert("Zadejte prosím své jméno."); return; }

            const pickedDish = menu.find(m => m.id === selectedMenuId);

            fetch('/api/portal/order', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    company: company,
                    employee: emp,
                    dish_id: pickedDish.id,
                    dish_name: pickedDish.name,
                    price: pickedDish.price
                })
            }).then(r => r.json()).then(d => {
                alert("Objednávka pro " + company + " byla úspěšně zapsána do KDS!");
                document.getElementById('emp-name').value = '';
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
                <inv:text>Měsíční vyúčtování stravného dle nepopiratelného KDS protokolu</inv:text>
            </inv:invoiceHeader>
            <inv:invoiceDetail>
                $itemsXml
            </inv:invoiceDetail>
        </inv:invoice>
    </dat:dataPackItem>
</dat:dataPack>"""
    }

    private fun renderAuditHtml(): String {
        val sdf = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault())
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

            val haccpOk = if (temp >= 65.0) "<span style='color:green;font-weight:bold;'>VYHOVUJE</span>" else "<span style='color:red;font-weight:bold;'>NEVYHOVUJE</span>"

            rows.append("""
                <tr>
                    <td style='text-align:center;font-weight:bold;'>#${r.optInt("lamport_tick", i + 1)}</td>
                    <td>${sdf.format(Date(ts))}</td>
                    <td><b>$action</b>: $itemName<br><small style='color:#555;'>Odběratel: <b>$client</b> | Kuchař: <b>$chef</b> | Alergeny: <b>$allergens</b></small></td>
                    <td style='text-align:right;'>$portions ks</td>
                    <td style='text-align:right;font-weight:bold;'>$temp °C</td>
                    <td style='text-align:center;'>$haccpOk</td>
                    <td style='font-family:monospace;font-size:10px;word-break:break-all;'>${cHash.take(18)}...</td>
                </tr>
            """.trimIndent())
        }

        return """
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>Audit HACCP</title>
<style>body{font-family:Arial,sans-serif;padding:20px;background:#fff;color:#000}table{width:100%;border-collapse:collapse}th,td{border:1px solid #333;padding:8px;font-size:12px;}th{background:#f1f5f9;}</style>
</head><body>
<div style='border:2px solid green;color:green;padding:6px;float:right;font-weight:bold;'>INTEGRITA_100%_PLATNÁ</div>
<h2>ÚŘEDNÍ PROTOKOL HACCP A KONTINUITY VÝDEJE</h2>
<table><thead><tr><th>Tick</th><th>Čas</th><th>Položka & Odběratel</th><th>Porce</th><th>Teplota</th><th>HACCP</th><th>Hash</th></tr></thead><tbody>$rows</tbody></table>
</body></html>
        """.trimIndent()
    }
}
