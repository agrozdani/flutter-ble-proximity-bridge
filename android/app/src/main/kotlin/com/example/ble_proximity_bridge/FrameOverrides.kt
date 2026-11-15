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
 *
 * A goodbye from an iPhone expires much sooner ([iphoneGoodbyeTtlMillis]).
 * An iPhone stops advertising and sending keep-alive notifications 0.3 s
 * after its goodbye (one keep-alive already scheduled can still follow
 * within 2 s), so apart from copies relayed by other peers, only readings
 * already under way can still carry its old online payload, and those end
 * within a few seconds. Holding the goodbye longer would hide the peer if it
 * restarts before our next re-read, and its hello cannot be counted on to
 * end the goodbye early: Herald's iOS immediateSendAll only reaches peers
 * the sender is connected to as a central, and Herald's stop() drops those
 * connections. An Android sender keeps advertising while its blocking send
 * works through its peers, so its goodbye keeps the full [ttlMillis].
 */
class FrameOverrides(
    /** How long a frame outvotes cached payloads if no fresh read ends it. */
    private val ttlMillis: Long,
    /** The same for a goodbye sent by an iPhone. */
    private val iphoneGoodbyeTtlMillis: Long,
    private val now: () -> Long = SystemClock::elapsedRealtime,
) {
    /** Where Herald got the payload it is handing over. */
    enum class Source {
        /**
         * Just read from the peer, or written to us by it. On iOS, a relayed
         * payload Herald does not already hold also arrives as a read.
         */
        READ,

        /** A goodbye/hello frame the peer pushed to us. */
        FRAME,

        /**
         * Herald's stored copy, attached to an RSSI reading, or a payload in
         * a relayed list: possibly stale.
         */
        CACHED,
    }

    /** The decoded fields of one payload. */
    data class Payload(
        val status: Int,
        val color: Int,
        val deviceKind: Int,
        val offline: Boolean,
    )

    private class Entry(val frame: Payload, val recordedAt: Long, val lifetime: Long)

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
            Source.FRAME -> entries[peerId] = Entry(payload, now(), lifetimeOf(payload))
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

    private fun lifetimeOf(frame: Payload): Long =
        if (frame.offline && frame.deviceKind == StatusPayloadSupplier.DEVICE_KIND_IOS) {
            iphoneGoodbyeTtlMillis
        } else {
            ttlMillis
        }

    private fun unexpiredFrame(peerId: Long): Payload? {
        val entry = entries[peerId] ?: return null
        if (now() - entry.recordedAt > entry.lifetime) {
            entries.remove(peerId)
            return null
        }
        return entry.frame
    }
}
