package com.medut.generic.phone.engine

/** Numbers and SIP addresses, written the way lib/sip/sip_service.dart does. */
object Numbers {
    /** "sip:201@pbx;transport=tls" or "Sara <sip:201@pbx>" -> "201". */
    fun userPart(uri: String): String {
        var s = uri.replace(Regex("^.*<"), "").replace(Regex(">.*$"), "")
        s = s.replace(Regex("^sips?:"), "")
        val at = s.indexOf('@')
        return if (at > 0) s.substring(0, at) else s
    }

    /**
     * What was typed, as an AOR on [domain]: a SIP address is used as is;
     * anything else is a number or extension there. A leading + becomes
     * [plusReplace], and outside numbers (7+ digits) get [dialPrefix].
     */
    fun uriFor(input: String, domain: String, port: Int, plusReplace: String, dialPrefix: String): String {
        var s = input.trim().replace(Regex("^sips?:"), "")
        if (s.contains('@')) return s
        s = s.replace(Regex("[\\s\\-().]"), "")
        if (s.startsWith("+") && plusReplace.isNotEmpty()) s = plusReplace + s.substring(1)
        // The line-out prefix is for outside numbers, not extensions or codes.
        if (dialPrefix.isNotEmpty() && Regex("^\\+?\\d{7,}$").matches(s)) s = dialPrefix + s
        return if (port > 0) "$s@$domain:$port" else "$s@$domain"
    }

    /** The Refer-To of a transfer: a full sip: URI (baresip takes anything else for a user name). */
    fun referUri(uri: String): String =
        if (Regex("^sips?:", RegexOption.IGNORE_CASE).containsMatchIn(uri)) uri else "sip:$uri"

    /** The same number however it is written: the last nine digits (people.dart). */
    fun sameNumber(a: String, b: String): Boolean {
        fun tail(n: String): String {
            val d = n.filter { it.isDigit() }
            return if (d.length > 9) d.substring(d.length - 9) else d
        }
        val x = tail(a)
        return x.isNotEmpty() && x == tail(b)
    }
}
