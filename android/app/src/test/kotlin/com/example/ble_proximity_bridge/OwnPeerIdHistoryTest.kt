package com.example.ble_proximity_bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Same cases as OwnPeerIdHistoryTests in ios/RunnerTests/RunnerTests.swift. */
class OwnPeerIdHistoryTest {

    private var stored: String? = null
    private var writes = 0
    private var clock = 1_000_000L

    private fun history() = OwnPeerIdHistory(
        read = { stored },
        write = { stored = it; writes++ },
        now = { clock },
    )

    @Test
    fun `a new id makes the last one previous, the current one is not`() {
        val history = history()
        history.noteCurrent(1)
        assertFalse(history.isPrevious(1))

        history.noteCurrent(2)
        assertTrue(history.isPrevious(1))
        assertFalse(history.isPrevious(2))
        assertFalse(history.isPrevious(3))
    }

    @Test
    fun `the same id again changes nothing`() {
        val history = history()
        history.noteCurrent(1)
        history.noteCurrent(1)

        assertEquals(emptyList<Long>(), history.previousIds())
    }

    @Test
    fun `the history survives a relaunch`() {
        history().noteCurrent(1)
        // The next launch, with a new id.
        val next = history()
        next.noteCurrent(2)
        assertTrue(next.isPrevious(1))

        val third = history()
        third.noteCurrent(3)
        assertEquals(listOf(1L, 2L), third.previousIds())
    }

    @Test
    fun `an id is forgotten after the retention`() {
        val history = history()
        history.noteCurrent(1)
        history.noteCurrent(2)

        clock += OwnPeerIdHistory.RETENTION_MILLIS
        assertTrue(history.isPrevious(1))
        clock += 1
        assertFalse(history.isPrevious(1))

        // And it is pruned from storage on the next change.
        history.noteCurrent(3)
        assertEquals(listOf(2L), history().previousIds())
    }

    @Test
    fun `only the newest ids are kept`() {
        val history = history()
        // Ids 0 to CAPACITY + 1: CAPACITY + 1 previous ones, the oldest dropped.
        for (id in 0L..OwnPeerIdHistory.CAPACITY + 1L) history.noteCurrent(id)

        val previous = history.previousIds()
        assertEquals(OwnPeerIdHistory.CAPACITY, previous.size)
        assertEquals(1L, previous.first())
        assertEquals(OwnPeerIdHistory.CAPACITY.toLong(), previous.last())
    }

    @Test
    fun `an id that comes back is current, not previous`() {
        val history = history()
        history.noteCurrent(1)
        history.noteCurrent(2)
        history.noteCurrent(1)

        assertFalse(history.isPrevious(1))
        assertEquals(listOf(2L), history.previousIds())
    }

    @Test
    fun `unreadable storage is ignored`() {
        stored = "garbage"
        history().noteCurrent(1)
        stored = "x|1@y,2@5,,3"
        val history = history()
        assertEquals(listOf(2L), history.previousIds())
        history.noteCurrent(9)
        assertEquals(listOf(2L), history.previousIds())
    }

    @Test
    fun `isPrevious never writes`() {
        val history = history()
        history.noteCurrent(1)
        val before = writes
        history.isPrevious(1)
        history.previousIds()
        assertEquals(before, writes)
    }
}
