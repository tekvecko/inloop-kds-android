package cz.inloop.kds

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.util.Base64

object CryptoManager {
    private const val KEY_ALIAS = "inloop_kds_tee_master_key"
    private const val KEYSTORE_NAME = "AndroidKeyStore"

    fun initHardwareKey(): Boolean {
        return try {
            val keyStore = KeyStore.getInstance(KEYSTORE_NAME).apply { load(null) }
            if (!keyStore.containsAlias(KEY_ALIAS)) {
                generateKey()
            }
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    private fun generateKey() {
        val keyPairGenerator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC,
            KEYSTORE_NAME
        )
        val parameterSpec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
        ).run {
            setDigests(KeyProperties.DIGEST_SHA256)
            setUserAuthenticationRequired(true)
            build()
        }
        keyPairGenerator.initialize(parameterSpec)
        keyPairGenerator.generateKeyPair()
    }

    fun getSignatureObject(): Signature? {
        return try {
            val keyStore = KeyStore.getInstance(KEYSTORE_NAME).apply { load(null) }
            val privateKey = keyStore.getKey(KEY_ALIAS, null) ?: run {
                generateKey()
                keyStore.getKey(KEY_ALIAS, null)
            }
            Signature.getInstance("SHA256withECDSA").apply {
                initSign(privateKey as java.security.PrivateKey)
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            // Při změně otisků v Androidu klíč obnovíme
            generateKey()
            val keyStore = KeyStore.getInstance(KEYSTORE_NAME).apply { load(null) }
            val privateKey = keyStore.getKey(KEY_ALIAS, null)
            Signature.getInstance("SHA256withECDSA").apply {
                initSign(privateKey as java.security.PrivateKey)
            }
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    fun signData(signature: Signature, data: ByteArray): String {
        signature.update(data)
        val signatureBytes = signature.sign()
        return Base64.getEncoder().encodeToString(signatureBytes)
    }

    fun getPublicKeyBase64(): String {
        return try {
            val keyStore = KeyStore.getInstance(KEYSTORE_NAME).apply { load(null) }
            val certificate = keyStore.getCertificate(KEY_ALIAS) ?: return "KEY_NOT_READY"
            Base64.getEncoder().encodeToString(certificate.publicKey.encoded)
        } catch (e: Exception) {
            "HARDWARE_TEE_INITIALIZING"
        }
    }
}
