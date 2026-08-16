package cz.inloop.kds

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.util.Base64

object CryptoManager {
    private const val KEY_ALIAS = "inloop_kds_tee_master_key_v2"
    private const val KEYSTORE_NAME = "AndroidKeyStore"

    fun isKeyEnrolled(): Boolean {
        return try {
            val keyStore = KeyStore.getInstance(KEYSTORE_NAME).apply { load(null) }
            keyStore.containsAlias(KEY_ALIAS)
        } catch (e: Exception) {
            false
        }
    }

    fun registerNewChefKey(): String {
        val keyStore = KeyStore.getInstance(KEYSTORE_NAME).apply { load(null) }
        if (keyStore.containsAlias(KEY_ALIAS)) {
            keyStore.deleteEntry(KEY_ALIAS)
        }
        generateKey()
        return getPublicKeyBase64()
    }

    private fun generateKey() {
        val keyPairGenerator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC,
            KEYSTORE_NAME
        )
        val builder = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
        ).apply {
            setDigests(KeyProperties.DIGEST_SHA256)
            setUserAuthenticationRequired(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                setUserAuthenticationParameters(
                    0,
                    KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL
                )
            }
        }
        keyPairGenerator.initialize(builder.build())
        keyPairGenerator.generateKeyPair()
    }

    fun getSignatureObject(): Signature? {
        return try {
            val keyStore = KeyStore.getInstance(KEYSTORE_NAME).apply { load(null) }
            if (!keyStore.containsAlias(KEY_ALIAS)) {
                generateKey()
            }
            val privateKey = keyStore.getKey(KEY_ALIAS, null) ?: return null
            Signature.getInstance("SHA256withECDSA").apply {
                initSign(privateKey as java.security.PrivateKey)
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
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
            val certificate = keyStore.getCertificate(KEY_ALIAS) ?: return "NENÍ_REGISTROVÁN"
            Base64.getEncoder().encodeToString(certificate.publicKey.encoded)
        } catch (e: Exception) {
            "CHYBA_HARDWARE_KEY"
        }
    }
}
