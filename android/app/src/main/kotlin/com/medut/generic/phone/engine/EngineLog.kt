package com.medut.generic.phone.engine

import java.time.LocalTime

/**
 * The two logs Settings shows: the connection log (registration, network,
 * SDK lines) and the SIP message trace. Kept in memory, as before. Each line
 * gets a sequence number so Flutter can fetch only what it has not seen.
 */
object EngineLog {
    private class Ring(val max: Int) {
        val lines = ArrayDeque<String>()
        var seq = 0L // lines ever added

        fun add(line: String) {
            lines.addLast(line)
            seq++
            while (lines.size > max) lines.removeFirst()
        }

        /** Lines after [since], or all that are left when [since] is too old. */
        fun after(since: Long): List<String> {
            val missing = (seq - since).coerceAtLeast(0)
            return if (missing >= lines.size) lines.toList() else lines.toList().takeLast(missing.toInt())
        }
    }

    private val conn = Ring(500)
    private val sip = Ring(400)

    @Synchronized
    fun conn(line: String) {
        val t = LocalTime.now()
        fun two(v: Int) = v.toString().padStart(2, '0')
        conn.add("${two(t.hour)}:${two(t.minute)}:${two(t.second)}  $line")
    }

    @Synchronized
    fun sip(entry: String) = sip.add(entry)

    private fun ring(kind: String) = if (kind == "sip") sip else conn

    @Synchronized
    fun seq(kind: String): Long = ring(kind).seq

    /** {seq, lines, reset}: reset when the caller must drop what it has. */
    @Synchronized
    fun read(kind: String, since: Long): Map<String, Any> {
        val r = ring(kind)
        val reset = since <= 0 || since > r.seq || r.seq - since > r.lines.size
        return mapOf("seq" to r.seq, "lines" to if (reset) r.lines.toList() else r.after(since), "reset" to reset)
    }
}
