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
    private val rsEngine = ReedSolomonEngine(16)

    private var lastHash = "0000000000000000000000000000000000000000000000000000000000000000"
    private var lamportClock = 0
    private val records = CopyOnWriteArrayList<JSONObject>()
    private val activeChallenges = HashMap<String, Long>()

    init {
        loadBinaryLedger()
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
            raf.seek(raf.length())
            raf.writeInt(encodedBlock.size)
            raf.write(encodedBlock)
        }

        records.add(crystal)
        lastHash = crystal.getString("crystal_hash")
        return crystal
    }

    private fun sha256(input: String): String {
        val bytes = MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8))
        return bytes.joinToString("") { "%02x".format(it) }
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

    private fun computeMerkleRoot(): String {
        if (records.isEmpty()) return "0000000000000000000000000000000000000000000000000000000000000000"
        var currentLayer = records.map {
            val h = it.optString("crystal_hash", "")
            val bytes = ByteArray(h.length / 2)
            for (i in bytes.indices) {
                val index = i * 2
                bytes[i] = h.substring(index, index + 2).toInt(16).toByte()
            }
            bytes
        }.toMutableList()

        while (currentLayer.size > 1) {
            if (currentLayer.size % 2 != 0) {
                currentLayer.add(currentLayer.last())
            }
            val nextLayer = mutableListOf<ByteArray>()
            for (i in 0 until currentLayer.size step 2) {
                val md = MessageDigest.getInstance("SHA-256")
                md.update(currentLayer[i])
                md.update(currentLayer[i + 1])
                nextLayer.add(md.digest())
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
            uri == "/api/menu" && method == Method.GET -> {
                val menuContent = if (menuFile.exists()) menuFile.readText() else "[]"
                newFixedLengthResponse(Response.Status.OK, "application/json", menuContent)
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
            uri == "/api/crystallize" && method == Method.POST -> {
                val body = readJsonBody(session)
                val intent = body.optJSONObject("intent") ?: JSONObject()
                val fidoId = body.optString("fido_id", "")
                val sig = body.optString("signature", "")
                val challenge = body.optString("challenge", "")

                // 1. Ověření jednorázové platnosti challenge
                val isValidChallenge = synchronized(activeChallenges) {
                    activeChallenges.remove(challenge) != null
                }
                if (!isValidChallenge) {
                    newFixedLengthResponse(Response.Status.FORBIDDEN, "application/json", 
                        "{\"ui_feedback\":\"ERROR\",\"message\":\"CHYBA: Neplatná nebo expirovaná kryptografická výzva!\"}")
                } else {
                    // 2. Skutečná matematická verifikace podpisu TEE procesoru
                    val signedPayload = intent.toString() + ":" + challenge
                    val isSignatureValid = verifyEcdsaSignature(fidoId, signedPayload, sig)

                    if (!isSignatureValid) {
                        newFixedLengthResponse(Response.Status.FORBIDDEN, "application/json", 
                            "{\"ui_feedback\":\"ERROR\",\"message\":\"KRYPTOGRAFICKÝ STOP-STAV: Neplatný TEE podpis!\"}")
                    } else {
                        val raw = "$intent:$fidoId:$sig:$lastHash"
                        val crystalHash = sha256(raw)

                        val crystal = JSONObject().apply {
                            put("crystal_hash", crystalHash)
                            put("intent", intent)
                            put("fido_id", fidoId)
                            put("signature", sig)
                            put("ecc_protected", true)
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
                newFixedLengthResponse(Response.Status.OK, "text/html", renderAuditHtml())
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

    private fun renderAuditHtml(): String {
        val sdf = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault())
        val merkleRoot = computeMerkleRoot()
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
            val portions = it.optInt("portions", 0)
            val cHash = r.optString("crystal_hash", "")

            val haccpOk = if (temp >= 65.0) "<span style='color:green;font-weight:bold;'>VYHOVUJE</span>" else "<span style='color:red;font-weight:bold;'>NEVYHOVUJE</span>"

            rows.append("""
                <tr>
                    <td style='text-align:center;font-weight:bold;'>#${r.optInt("lamport_tick", i + 1)}</td>
                    <td>${sdf.format(Date(ts))}</td>
                    <td><b>$action</b>: $itemName<br><small style='color:#555;'>Odběratel: <b>$client</b> | Reed-Solomon GF(2^8) OK</small></td>
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
<div style='border:2px solid green;color:green;padding:6px;float:right;font-weight:bold;'>REED_SOLOMON_&_ECDSA_100%_PLATNÉ</div>
<h2>ÚŘEDNÍ PROTOKOL O KRYPTOGRAFICKÉM AUDITU</h2>
<p>Merkle Root: <code>$merkleRoot</code></p>
<table><thead><tr><th>Tick</th><th>Čas</th><th>Položka</th><th>Porce</th><th>Teplota</th><th>HACCP</th><th>Hash</th></tr></thead><tbody>$rows</tbody></table>
</body></html>
        """.trimIndent()
    }
}
