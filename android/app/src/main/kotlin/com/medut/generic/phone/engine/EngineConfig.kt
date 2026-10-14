package com.medut.generic.phone.engine

import android.content.Context
import dev.medut.IceServer
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDateTime

/** "Numbers matching [pattern] go out through [accountId]": X is any digit, else a prefix. */
class DialRule(val pattern: String, val accountId: String) {
    fun matches(number: String): Boolean {
        val n = number.replace(Regex("[\\s\\-()]"), "")
        if (!pattern.contains('X')) return n.startsWith(pattern)
        if (n.length != pattern.length) return false
        for (i in n.indices) {
            val p = pattern[i]
            if (p == 'X') {
                if (!n[i].isDigit()) return false
            } else if (p != n[i]) {
                return false
            }
        }
        return true
    }
}

/**
 * The app settings the engine works from, as Dart last pushed them
 * (`setConfig`) and kept across restarts, so a call that rings with no
 * Flutter engine up follows the same rules and speaks the same language.
 * Keys and defaults are those of `AppSettings` in lib/core/settings.dart.
 */
class EngineConfig(private val j: JSONObject) {
    private fun s(k: String, d: String) = if (j.has(k) && !j.isNull(k)) j.optString(k, d) else d
    private fun b(k: String, d: Boolean) = if (j.has(k)) j.optBoolean(k, d) else d
    private fun i(k: String, d: Int) = if (j.has(k)) j.optInt(k, d) else d

    private fun strings(k: String): List<String> {
        val a = j.optJSONArray(k) ?: return emptyList()
        return (0 until a.length()).map { a.optString(it) }
    }

    private val labels: JSONObject = j.optJSONObject("labels") ?: JSONObject()

    /** Translated text from Dart's string table, so native and Flutter share one. */
    fun label(key: String, fallback: String): String =
        labels.optString(key, "").ifEmpty { fallback }

    /** [label] with `{name}` style placeholders filled in. */
    fun label(key: String, fallback: String, vararg args: Pair<String, String>): String {
        var t = label(key, fallback)
        for ((k, v) in args) t = t.replace("{$k}", v)
        return t
    }

    fun labelMap(): Map<String, String> = labels.keys().asSequence().associateWith { labels.optString(it) }

    val dark get() = b("dark", false)
    val rtl get() = b("rtl", false)

    // Audio and network (every account)
    val codecs: List<String> get() = strings("codecs").ifEmpty { listOf("alaw", "ulaw", "opus") }
    val jitterMode get() = s("jitterMode", "auto")
    val aecMode get() = i("aecMode", 2)
    val noiseSuppression get() = b("ns", true)
    val autoGain get() = b("agc", true)
    val forceRelay get() = b("forceRelay", false)
    val regExpires get() = i("regExpires", 300)
    val keepaliveSec get() = i("keepaliveSec", 30)
    val debugLogging get() = b("debugLogging", false)
    val traceSip get() = b("traceSip", true)

    val iceServers: List<IceServer>
        get() {
            val a = j.optJSONArray("iceServers") ?: return emptyList()
            return (0 until a.length()).mapNotNull { n ->
                val o = a.optJSONObject(n) ?: return@mapNotNull null
                val url = o.optString("url").trim()
                if (url.isEmpty()) null
                else IceServer(url, o.optString("user").trim().ifEmpty { null }, o.optString("pass").trim().ifEmpty { null })
            }
        }

    // Ringing
    /** A file path, or "system" for the phone's ringtone. */
    val ringtone get() = s("ringtone", "system")
    val vibrate get() = b("vibrate", true)
    val ringback get() = b("ringback", true)

    // Calls
    val autoAnswer get() = b("autoAnswer", false)
    val autoAnswerDelay get() = i("autoAnswerDelay", 3)
    val showCallQuality get() = b("showCallQuality", true)
    val blocked: Set<String> get() = strings("blocked").toSet()
    val keepAlive get() = b("keepAlive", true)

    // Your status
    val status get() = s("status", "available")
    val officeHours get() = b("officeHours", false)
    val officeDays: List<Int>
        get() = s("officeDays", "7,1,2,3,4").split(',').mapNotNull { it.trim().toIntOrNull() }
    val officeStart get() = s("officeStart", "09:00")
    val officeEnd get() = s("officeEnd", "17:00")
    val letFavourites get() = b("letFavourites", true)
    val letRepeat get() = b("letRepeat", true)
    val favourites: Set<String> get() = strings("favourites").toSet()
    val queueIn: Set<String> get() = strings("queueIn").toSet()

    /** Colleagues on the Team list: (name, extension). */
    val watched: List<Pair<String, String>>
        get() {
            val a = j.optJSONArray("watched") ?: return emptyList()
            return (0 until a.length()).mapNotNull { n ->
                val o = a.optJSONObject(n) ?: return@mapNotNull null
                o.optString("name") to o.optString("ext")
            }
        }

    // Recording: off | manual | always, and the folder Dart resolved.
    val recordingMode get() = s("recordingMode", "manual")
    val recordingDir get() = s("recordingDir", "")

    val dialRules: List<DialRule>
        get() {
            val a = j.optJSONArray("dialRules") ?: return emptyList()
            return (0 until a.length()).mapNotNull { n ->
                val o = a.optJSONObject(n) ?: return@mapNotNull null
                DialRule(o.optString("pattern"), o.optString("accountId"))
            }
        }

    /** Missed calls after this (ms) count toward the badge and the notification. */
    val activitySeenAt: Long get() = j.optLong("activitySeenAt", System.currentTimeMillis())

    /**
     * The status in force now: Do not disturb outside office hours when that
     * switch is on, otherwise the one the user picked (AppSettings.effectiveStatus).
     */
    fun effectiveStatus(now: LocalDateTime = LocalDateTime.now()): String {
        if (!officeHours) return status
        fun mins(hhmm: String): Int {
            val p = hhmm.split(':')
            return (p.getOrNull(0)?.toIntOrNull() ?: 0) * 60 + (p.getOrNull(1)?.toIntOrNull() ?: 0)
        }
        val inDay = officeDays.contains(now.dayOfWeek.value) // Monday 1 … Sunday 7, as in Dart
        val m = now.hour * 60 + now.minute
        val inHours = m >= mins(officeStart) && m < mins(officeEnd)
        return if (inDay && inHours) status else "dnd"
    }

    fun toJson(): JSONObject = j

    companion object {
        private const val PREFS = "medut_engine"
        private const val KEY = "config"

        fun load(context: Context): EngineConfig {
            val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)
            return EngineConfig(runCatching { JSONObject(raw ?: "{}") }.getOrElse { JSONObject() })
        }

        fun save(context: Context, j: JSONObject) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, j.toString()).apply()
        }

        fun fromMap(map: Map<*, *>): JSONObject = JSONObject(map.mapKeys { it.key.toString() }.mapValues { wrap(it.value) })

        /** Method-channel values (maps, lists, primitives) as JSON. */
        fun wrap(v: Any?): Any? = when (v) {
            null -> JSONObject.NULL
            is Map<*, *> -> fromMap(v)
            is List<*> -> JSONArray(v.map { wrap(it) })
            else -> v
        }
    }
}
