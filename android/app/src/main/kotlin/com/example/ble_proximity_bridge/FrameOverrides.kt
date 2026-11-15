package com.example.ble_proximity_bridge

import android.os.SystemClock

/**
 * Decides which payload to believe for a peer: the one Herald just handed
 * over, or what the peer last announced in a goodbye/hello frame.
 *
 * A frame is pushed precisely because the receiver's copy of the payload is
 * out of date, but Herald does not update that copy from a frame: it keeps
 * reporting every RSSI reading together with the payload it last *read*.
 * Taken at face value, the stale copy overrules the frame on the next
 * reading — a peer that said goodbye pops back with its old online payload,
 * and a peer that said hello is removed again by its old offline one.
 *
 * So a frame is remembered per peer and outvotes cached payloads until a
 * fresh read of that peer's payload supersedes it. Entries also expire, so a
 * frame cannot outvote the payload forever if that read never happens.
 */
class FrameOverrides(
    private val ttlMillis: Long,
    private val now: () -> Long = SystemClock::elapsedRealtime,
) {
    /** Where Herald got the payload it is handing over. */
    enum class Source {
        /** Just read from the peer itself (or written to us by it). */
        READ,

        /** A goodbye/hello frame the peer pushed to us. */
        FRAME,

        /** Herald's stored copy, or a copy relayed by another peer: possibly stale. */
        CACHED,
    }

    /** The decoded fields of one payload. */
    data class Payload(
        val status: Int,
        val color: Int,
        val deviceKind: Int,
        val offline: Boolean,
    )

    private class Entry(val frame: Payload, val recordedAt: Long)

    private val entries = HashMap<Long, Entry>()

    /**
     * Returns the payload to act on for this peer, or null when [payload]
     * must be ignored: a cached copy of a peer whose goodbye frame was
     * already reported.
     */
    @Synchronized
    fun resolve(peerId: Long, source: Source, payload: Payload): Payload? {
        when (source) {
            // Newer than any frame, so the frame's job is done.
            Source.READ -> entries.remove(peerId)
            Source.FRAME -> entries[peerId] = Entry(payload, now())
            Source.CACHED -> {
                val frame = unexpiredFrame(peerId) ?: return payload
                // After a hello, report the peer as the frame described it.
                return if (frame.offline) null else frame
            }
        }
        return payload
    }

    @Synchronized
    fun clearAll() {
        entries.clear()
    }

    private fun unexpiredFrame(peerId: Long): Payload? {
        val entry = entries[peerId] ?: return null
        if (now() - entry.recordedAt > ttlMillis) {
            entries.remove(peerId)
            return null
        }
        return entry.frame
    }
}
