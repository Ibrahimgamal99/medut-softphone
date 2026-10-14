package com.medut.generic.phone.engine

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import dev.medut.AccountConfig
import dev.medut.DtmfMode
import dev.medut.IceServer
import dev.medut.IceTransportPolicy
import dev.medut.MediaEncryption
import dev.medut.PushProvider
import dev.medut.Transport
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Status feature codes as each PBX ships them (kPbxPresets in lib/core/accounts.dart). */
private val PBX_PRESETS = mapOf(
    "freepbx" to mapOf("dndOn" to "*78", "dndOff" to "*79", "queueLogin" to "*45", "queueLogout" to "*45"),
    "fusionpbx" to mapOf("dndOn" to "*78", "dndOff" to "*79", "queueLogin" to "*22", "queueLogout" to "*22"),
    "3cx" to mapOf("dndOn" to "", "dndOff" to "", "queueLogin" to "*62", "queueLogout" to "*63"),
)

/**
 * One SIP account as the user configured it: the JSON of Dart's
 * `SipAccountConfig.toJson()` plus `password` and `turnPass`.
 */
class AccountCfg(val json: JSONObject) {
    private fun s(k: String, d: String = "") = if (json.isNull(k)) d else json.optString(k, d)
    private fun b(k: String, d: Boolean) = if (json.has(k)) json.optBoolean(k, d) else d

    val id get() = s("id")
    val name get() = s("name")
    val user get() = s("user")
    val domain get() = s("domain")
    val password get() = s("password")
    val transport get() = s("transport", "udp")
    val port get() = json.optInt("port", 0)
    val serverUrl get() = s("serverUrl")
    val authUser get() = s("authUser")
    val displayName get() = s("displayName")
    val outboundProxy get() = s("outboundProxy")
    val mediaEnc get() = s("mediaEnc", "none")
    val ice get() = b("ice", false)
    val stun get() = s("stun")
    val turn get() = s("turn")
    val turnUser get() = s("turnUser")
    val turnPass get() = s("turnPass")
    val verifyTls get() = b("verifyTls", true)
    val enabled get() = b("enabled", true)
    val isDefault get() = b("isDefault", false)
    val push get() = b("push", true)
    val dtmf get() = s("dtmf", "rfc4733")
    val recordCalls get() = b("recordCalls", true)
    val dialPrefix get() = s("dialPrefix")
    val plusReplace get() = s("plusReplace")
    val headers get() = s("headers")
    val pbx get() = s("pbx", "freepbx")

    /** `user@domain[:port]`, as the SDK expects the AOR. */
    val aor get() = if (port > 0) "$user@$domain:$port" else "$user@$domain"
    val label get() = name.ifEmpty { domain }

    /** The status feature code for [key] ('' = this PBX has none). */
    fun code(key: String): String {
        val own = json.optJSONObject("codes")
        if (own != null && own.has(key)) return own.optString(key)
        return PBX_PRESETS[pbx]?.get(key) ?: ""
    }

    /** The app-wide codec order, except that a web link puts Opus first. */
    fun codecsFrom(order: List<String>): List<String> =
        if (transport == "ws" || transport == "wss") listOf("opus") + order.filter { it != "opus" } else order

    /**
     * What the SDK account is built from: a change here re-creates it (and
     * re-registers). Settings only the app reads are left out, so renaming an
     * account does not drop its registration (SipService._signature).
     */
    fun signature(config: EngineConfig, pushProvider: String): String {
        val j = JSONObject(json.toString())
        for (k in listOf("name", "isDefault", "voicemail", "recordCalls", "dialPrefix", "plusReplace", "pbx", "codes")) j.remove(k)
        val ice = config.iceServers.joinToString(",") { "${it.url}|${it.username}|${it.password}" }
        return "$j|${if (push) pushProvider else ""}|$ice|${config.forceRelay}|${config.codecs}"
    }

    fun toSdk(config: EngineConfig, pushProvider: PushProvider, pushToken: String?, pushParam: String?): AccountConfig {
        fun opt(v: String) = v.trim().ifEmpty { null }
        val usePush = push && pushToken != null && pushProvider != PushProvider.NONE
        return AccountConfig(
            uri = aor,
            password = password,
            transport = when (transport) {
                "tcp" -> Transport.TCP
                "tls" -> Transport.TLS
                "ws" -> Transport.WS
                "wss" -> Transport.WSS
                else -> Transport.UDP
            },
            serverUrl = if (transport == "ws" || transport == "wss") opt(serverUrl) else null,
            authUser = opt(authUser),
            displayName = opt(displayName),
            outboundProxy = opt(outboundProxy),
            mediaEncryption = when (mediaEnc) {
                "sdes" -> MediaEncryption.SDES
                "dtls" -> MediaEncryption.DTLS_SRTP
                else -> MediaEncryption.NONE
            },
            iceEnabled = ice,
            stunServer = opt(stun),
            turnServer = opt(turn),
            turnUser = opt(turnUser),
            turnPass = opt(turnPass),
            iceServers = config.iceServers,
            iceTransportPolicy = if (config.forceRelay) IceTransportPolicy.RELAY else IceTransportPolicy.ALL,
            verifyTls = verifyTls,
            pushProvider = if (usePush) pushProvider else PushProvider.NONE,
            pushToken = if (usePush) pushToken else null,
            pushParam = if (usePush) pushParam else null,
            audioCodecs = codecsFrom(config.codecs),
            dtmfMode = when (dtmf) {
                "info" -> DtmfMode.SIP_INFO
                "auto" -> DtmfMode.AUTO
                else -> DtmfMode.RFC4733
            },
        )
    }

    /** "Name: value" lines of [headers]. */
    fun headerPairs(): List<Pair<String, String>> = headers.split('\n').mapNotNull { line ->
        val i = line.indexOf(':')
        if (i > 0) line.substring(0, i).trim() to line.substring(i + 1).trim() else null
    }
}

/**
 * The accounts, kept by native so a push or a reboot can register them with
 * no Flutter engine up. One file, AES-GCM with a key in the Android Keystore
 * (the SIP and TURN passwords are in it). Flutter reads and replaces the
 * whole list over the channel.
 */
class AccountRepository(context: Context) {
    private val file = File(context.filesDir, "engine/accounts.json.enc")
    private var cache: List<AccountCfg>? = null

    @Synchronized
    fun all(): List<AccountCfg> {
        cache?.let { return it }
        val list = read()
        cache = list
        return list
    }

    @Synchronized
    fun replace(list: List<AccountCfg>) {
        write(JSONArray(list.map { it.json }))
        cache = list
    }

    fun byId(id: String?): AccountCfg? = all().firstOrNull { it.id == id }

    /** The default account: the enabled one marked default, else the first enabled. */
    fun defaultAccount(): AccountCfg? {
        val enabled = all().filter { it.enabled }
        return enabled.firstOrNull { it.isDefault } ?: enabled.firstOrNull()
    }

    private fun read(): List<AccountCfg> {
        if (!file.exists()) return emptyList()
        return try {
            val a = JSONArray(String(decrypt(file.readBytes()), Charsets.UTF_8))
            (0 until a.length()).mapNotNull { a.optJSONObject(it)?.let(::AccountCfg) }
        } catch (e: Exception) {
            Log.e(TAG, "accounts unreadable", e)
            emptyList()
        }
    }

    private fun write(a: JSONArray) {
        file.parentFile?.mkdirs()
        val tmp = File(file.path + ".tmp")
        tmp.writeBytes(encrypt(a.toString().toByteArray(Charsets.UTF_8)))
        if (!tmp.renameTo(file)) {
            file.delete()
            tmp.renameTo(file)
        }
    }

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (ks.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private fun encrypt(plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val iv = cipher.iv
        return byteArrayOf(iv.size.toByte()) + iv + cipher.doFinal(plain)
    }

    private fun decrypt(blob: ByteArray): ByteArray {
        val ivLen = blob[0].toInt()
        val iv = blob.copyOfRange(1, 1 + ivLen)
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
        return cipher.doFinal(blob, 1 + ivLen, blob.size - 1 - ivLen)
    }

    private companion object {
        const val TAG = "MedutAccounts"
        const val KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "medut.app.accounts"
        const val TRANSFORM = "AES/GCM/NoPadding"
    }
}
