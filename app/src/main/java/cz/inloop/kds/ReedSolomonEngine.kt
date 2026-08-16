package cz.inloop.kds

class ReedSolomonEngine(private val nsym: Int = 16) {
    private val exp = IntArray(512)
    private val log = IntArray(256)

    init {
        var x = 1
        for (i in 0 until 255) {
            exp[i] = x
            log[x] = i
            x = x shl 1
            if (x >= 256) {
                x = x xor 0x11d
            }
        }
        for (i in 255 until 512) {
            exp[i] = exp[i - 255]
        }
    }

    private fun gfMul(x: Int, y: Int): Int {
        if (x == 0 || y == 0) return 0
        return exp[log[x] + log[y]]
    }

    private fun generatorPoly(): IntArray {
        var g = intArrayOf(1)
        for (i in 0 until nsym) {
            val next = IntArray(g.size + 1)
            val factor = exp[i]
            for (j in g.indices) {
                next[j] = next[j] xor gfMul(g[j], factor)
                next[j + 1] = next[j + 1] xor g[j]
            }
            g = next
        }
        return g
    }

    fun encode(data: ByteArray): ByteArray {
        val gen = generatorPoly()
        val msg = IntArray(data.size + nsym)
        for (i in data.indices) {
            msg[i] = data[i].toInt() and 0xFF
        }

        for (i in data.indices) {
            val coef = msg[i]
            if (coef != 0) {
                for (j in gen.indices) {
                    msg[i + j] = msg[i + j] xor gfMul(gen[j], coef)
                }
            }
        }

        val result = ByteArray(data.size + nsym)
        System.arraycopy(data, 0, result, 0, data.size)
        for (i in 0 until nsym) {
            result[data.size + i] = msg[data.size + i].toByte()
        }
        return result
    }

    fun verifyAndExtract(block: ByteArray): ByteArray? {
        if (block.size <= nsym) return null
        val dataSize = block.size - nsym
        val rawData = ByteArray(dataSize)
        System.arraycopy(block, 0, rawData, 0, dataSize)

        val reEncoded = encode(rawData)
        for (i in block.indices) {
            if (block[i] != reEncoded[i]) {
                return null
            }
        }
        return rawData
    }
}
