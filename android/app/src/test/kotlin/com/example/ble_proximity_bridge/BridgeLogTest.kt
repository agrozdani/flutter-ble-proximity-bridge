package com.example.ble_proximity_bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** What BridgeLog hands to logcat, which cuts an entry off at about 4 KB. */
class BridgeLogTest {

    @Test
    fun `an ordinary line is one logcat entry`() {
        val line = "2026-11-16 10:15:03.123 I native.host [main] Herald host started"
        assertEquals(listOf(line), BridgeLog.logcatParts(line))
    }

    @Test
    fun `a stack trace is one entry per line`() {
        val line = "2026-11-16 10:15:03.123 W native.frame [frame-sender] goodbye failed: boom\n" +
            "    java.lang.IllegalStateException: boom\n" +
            "    \tat com.example.Foo.bar(Foo.kt:1)"
        assertEquals(line.split('\n'), BridgeLog.logcatParts(line))
    }

    @Test
    fun `a line over the limit goes out in pieces that fit, the later ones indented`() {
        val head = "2026-11-16 10:15:03.123 I native.method [main] start session="
        val line = head + "x".repeat(6000) + " self=00000001 mock=false"
        val parts = BridgeLog.logcatParts(line)

        assertTrue(parts.size > 1)
        assertTrue(parts.first().startsWith(head))
        assertTrue(parts.drop(1).all { it.startsWith("    ") })
        assertTrue(parts.last().endsWith(" self=00000001 mock=false"))
        // Nothing is lost: without the indents, the pieces are the line.
        assertEquals(line, parts.first() + parts.drop(1).joinToString("") { it.removePrefix("    ") })
        // Each fits an entry even if every char takes 3 bytes of UTF-8.
        val limitBytes = 4000
        assertTrue(parts.all { it.length * 3 <= limitBytes + 12 })
        val widest = "→".repeat(BridgeLog.LOGCAT_MAX_CHARS + 5)
        assertTrue(BridgeLog.logcatParts(widest).all { it.toByteArray().size <= limitBytes })
    }
}
