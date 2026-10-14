package com.medut.generic.phone.engine

/**
 * Call quality grade 0–4: MOS and the network weighed together, so the bars,
 * the word and their colour always agree (lib/sip/quality.dart, which the
 * call history still uses: keep the two the same).
 *
 * 4 excellent · 3 good · 2 fair · 1 poor · 0 checking (no sample yet).
 * The network side is judged against the usual VoIP targets: round trip
 * under 150 ms, jitter under 20 ms, loss under 1 %. Missing a target counts
 * once, missing it twice over counts twice.
 */
object Quality {
    fun level(mos: Double?, rttMs: Double?, jitterMs: Double?, lossPct: Double?): Int {
        val byMos: Int? = when {
            mos == null || mos <= 0 -> null
            mos >= 4.3 -> 4
            mos >= 3.6 -> 3
            mos >= 3.1 -> 2
            else -> 1
        }
        var measured = 0
        var misses = 0
        fun judge(v: Double?, target: Double) {
            if (v == null) return
            measured++
            if (v >= target * 2) misses += 2 else if (v >= target) misses += 1
        }
        judge(rttMs, 150.0)
        judge(jitterMs, 20.0)
        judge(lossPct, 1.0)
        val byNetwork: Int? = if (measured == 0) null else when (misses) {
            0 -> 4
            1 -> 2
            else -> 1
        }
        // Excellent needs a MOS: clean counters alone are not evidence of one.
        if (byMos == null) return if (byNetwork == null) 0 else minOf(byNetwork, 3)
        if (byNetwork == null) return byMos
        return minOf(byMos, byNetwork)
    }

    /** Translation key for the grade's word. */
    fun wordKey(level: Int): String = when (level) {
        4 -> "signalExcellent"
        3 -> "signalGood"
        2 -> "signalFair"
        1 -> "signalPoor"
        else -> "signalChecking"
    }

    fun wordFallback(level: Int): String = when (level) {
        4 -> "Excellent"
        3 -> "Good"
        2 -> "Fair"
        1 -> "Poor"
        else -> "Checking…"
    }
}
