package com.medut.generic.phone.engine

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.LocalDateTime

/** The engine's rules, checked against the cases test/core_test.dart checks in Dart. */
class EngineLogicTest {

    @Test
    fun qualityGradeWeighsMosAndNetwork() {
        assertEquals(0, Quality.level(null, null, null, null))
        assertEquals(4, Quality.level(4.4, 40.0, 5.0, 0.0))
        // Clean counters alone are not evidence of excellent.
        assertEquals(3, Quality.level(null, 40.0, 5.0, 0.0))
        // A good MOS on a network missing a target twice over is poor.
        assertEquals(1, Quality.level(4.4, 320.0, 5.0, 0.0))
        assertEquals(2, Quality.level(4.4, 160.0, 5.0, 0.0))
        assertEquals(2, Quality.level(3.2, null, null, null))
        assertEquals("signalChecking", Quality.wordKey(0))
        assertEquals("signalExcellent", Quality.wordKey(4))
    }

    @Test
    fun dialRulesMatchPatternsAndPrefixes() {
        assertTrue(DialRule("0XXXXXXXXXX", "a").matches("010 1234 5678"))
        assertFalse(DialRule("0XXXXXXXXXX", "a").matches("0101234567"))
        assertTrue(DialRule("9", "a").matches("9123"))
        assertFalse(DialRule("9", "a").matches("123"))
    }

    @Test
    fun numbersBecomeAddressesOnTheAccountsDomain() {
        assertEquals("201@pbx.example.com", Numbers.uriFor("201", "pbx.example.com", 0, "", ""))
        assertEquals("201@pbx.example.com:5080", Numbers.uriFor("sip:201", "pbx.example.com", 5080, "", ""))
        assertEquals("sara@other.org", Numbers.uriFor("sip:sara@other.org", "pbx.example.com", 0, "", ""))
        // + becomes the international prefix, the line-out prefix only on outside numbers.
        assertEquals("900201001234567@pbx", Numbers.uriFor("+20 100 123-4567", "pbx", 0, "00", "9"))
        assertEquals("*78@pbx", Numbers.uriFor("*78", "pbx", 0, "00", "9"))
        assertEquals("201@pbx", Numbers.uriFor("201", "pbx", 0, "00", "9"))
        assertEquals("sip:202@pbx", Numbers.referUri("202@pbx"))
        assertEquals("sips:202@pbx", Numbers.referUri("sips:202@pbx"))
        assertEquals("201", Numbers.userPart("\"Sara\" <sip:201@pbx;transport=tls>"))
        assertEquals("201", Numbers.userPart("sip:201@pbx"))
        assertTrue(Numbers.sameNumber("+20 100 123 4567", "0100-123-4567"))
        assertFalse(Numbers.sameNumber("", ""))
    }

    @Test
    fun recordingsAreNamedLikeThePhonesRecorder() {
        val at = LocalDateTime.of(2026, 10, 13, 18, 24, 5)
        assertEquals("201 Sara_261013_182405.wav", Recordings.name("201", "Sara", at))
        assertEquals("201_261013_182405.wav", Recordings.name("201", "201", at))
        assertEquals("call_261013_182405.wav", Recordings.name("", "", at))
        assertEquals("a_b_261013_182405.wav", Recordings.name("a/b", "", at))
    }

    @Test
    fun anUnfinishedWavGetsItsSizesBack() {
        val f = File.createTempFile("medut", ".wav")
        try {
            // A 44-byte header saying "no data", then one second of 8 kHz 16-bit mono.
            val header = ByteArray(44)
            "RIFF".toByteArray().copyInto(header, 0)
            "WAVE".toByteArray().copyInto(header, 8)
            "fmt ".toByteArray().copyInto(header, 12)
            "data".toByteArray().copyInto(header, 36)
            fun le(v: Int, at: Int) { for (i in 0..3) header[at + i] = (v shr (8 * i) and 0xff).toByte() }
            le(16000, 28) // byte rate
            header[32] = 2 // block align
            f.writeBytes(header + ByteArray(16000))
            Recordings.repairWav(f.path)
            assertEquals(1, Recordings.wavSeconds(f.path))
            val h = f.readBytes()
            fun u32(at: Int) = (0..3).sumOf { (h[at + it].toInt() and 0xff) shl (8 * it) }
            assertEquals(16000, u32(40))
            assertEquals(36 + 16000, u32(4))
        } finally {
            f.delete()
        }
        assertNull(Recordings.wavSeconds("/nonexistent.wav"))
    }

    private fun account(extra: Map<String, Any> = emptyMap()) = AccountCfg(JSONObject(mapOf(
        "id" to "a1", "name" to "Office", "user" to "201", "domain" to "pbx.example.com",
        "transport" to "tls", "password" to "secret",
    ) + extra))

    @Test
    fun accountsReadDartsJson() {
        val a = account()
        assertEquals("201@pbx.example.com", a.aor)
        assertEquals("Office", a.label)
        // PBX presets fill the codes, and an account can override them.
        assertEquals("*78", a.code("dndOn"))
        assertEquals("*63", account(mapOf("pbx" to "3cx")).code("queueLogout"))
        assertEquals("*90", account(mapOf("codes" to JSONObject(mapOf("dndOn" to "*90")))).code("dndOn"))
        // A web link puts Opus first.
        assertEquals(listOf("alaw", "ulaw", "opus"), a.codecsFrom(listOf("alaw", "ulaw", "opus")))
        assertEquals(listOf("opus", "alaw", "ulaw"), account(mapOf("transport" to "wss")).codecsFrom(listOf("alaw", "ulaw", "opus")))
        assertEquals(listOf("X-A" to "1", "X-B" to "two: parts"), account(mapOf("headers" to "X-A: 1\nX-B: two: parts\nbad")).headerPairs())
    }

    @Test
    fun renamingAnAccountKeepsItsRegistration() {
        val config = EngineConfig(JSONObject())
        val sig = account().signature(config, "NONE")
        assertEquals(sig, account(mapOf("name" to "Home", "dialPrefix" to "9", "isDefault" to true)).signature(config, "NONE"))
        assertNotEquals(sig, account(mapOf("password" to "other")).signature(config, "NONE"))
        assertNotEquals(sig, account().signature(EngineConfig(JSONObject(mapOf("forceRelay" to true))), "NONE"))
    }

    @Test
    fun officeHoursTurnIntoDoNotDisturb() {
        val cfg = EngineConfig(JSONObject(mapOf(
            "status" to "ready", "officeHours" to true, "officeDays" to "7,1,2,3,4",
            "officeStart" to "09:00", "officeEnd" to "17:00",
        )))
        // 2026-10-14 is a Wednesday.
        assertEquals("ready", cfg.effectiveStatus(LocalDateTime.of(2026, 10, 14, 10, 0)))
        assertEquals("dnd", cfg.effectiveStatus(LocalDateTime.of(2026, 10, 14, 17, 0)))
        // Friday is not an office day here.
        assertEquals("dnd", cfg.effectiveStatus(LocalDateTime.of(2026, 10, 16, 10, 0)))
        assertEquals("available", EngineConfig(JSONObject()).effectiveStatus())
    }

    @Test
    fun labelsFillTheirPlaceholders() {
        val cfg = EngineConfig(JSONObject(mapOf("labels" to JSONObject(mapOf("missedCalls" to "{n} missed calls")))))
        assertEquals("3 missed calls", cfg.label("missedCalls", "x", "n" to "3"))
        assertEquals("Fallback", cfg.label("absent", "Fallback"))
    }
}
