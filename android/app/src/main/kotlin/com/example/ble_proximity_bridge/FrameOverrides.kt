package com.example.ble_proximity_bridge

import android.os.SystemClock

/**
 * Decides which payload to believe for a peer: the one Herald just handed
 * over, what the peer last announced in a goodbye/hello frame, or the newest
 * payload seen from it.
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
 *
 * Payloads from protocol version 3 on also carry a revision, which the
 * sender bumps on every change. The newest revision a peer sent us, in a
 * frame or a read, is remembered for [revisionMemoryMillis] after it last
 * arrived that way. Cached copies are never remembered: Herald's own repeats
 * the payload it last read, already reported as a read, and a relay's can be
 * older still, so remembering them would keep an old revision alive for as
 * long as readings repeat it. While a revision is remembered, a frame or read
 * older than it is dropped: a frame delivered late, a read that a frame
 * overtook, or a stale copy relayed by another peer. A cached payload older
 * than it is described by the newest payload instead when that one is
 * online. When the newest is an offline frame whose lifetime has run out,
 * the cached payload is taken at face value: readings carrying the old copy
 * then most likely mean the peer restarted and its hello was lost. Without
 * revisions (older peers), only the frame rule above applies.
 *
 * Revisions only order the payloads of one sender process. Each process
 * starts its counter again (see [RevisionCounter]), so a peer id reused by a
 * new process looks older than what is remembered of the old one, and its
 * payloads are dropped or overruled until that memory lapses.
 */
class FrameOverrides(
    /** How long a frame outvotes cached payloads if no fresh read ends it. */
    private val ttlMillis: Long,
    /** The same for a goodbye sent by an iPhone. */
    private val iphoneGoodbyeTtlMillis: Long,
    /** How long a peer's newest revision is remembered after its last frame or read. */
    private val revisionMemoryMillis: Long,
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

    /** The decoded fields of one payload; [revision] is null before version 3. */
    data class Payload(
        val status: Int,
        val color: Int,
        val deviceKind: Int,
        val offline: Boolean,
        val revision: Int? = null,
    )

    private enum class Order { NEWER, SAME, OLDER }

    private class Frame(val payload: Payload, val recordedAt: Long, val lifetime: Long)

    private class Newest(val payload: Payload, val confirmedAt: Long, val fromFrame: Boolean)

    private val frames = HashMap<Long, Frame>()
    private val newest = HashMap<Long, Newest>()
    private var lastSweep = now()

    /**
     * Returns the payload to act on for this peer, or null when [payload]
     * must be ignored: a cached copy of a peer whose goodbye frame was
     * already reported, or a payload older than one already seen.
     */
    @Synchronized
    fun resolve(peerId: Long, source: Source, payload: Payload): Payload? {
        sweepIfDue()
        val known = unexpiredNewest(peerId)
        val stale = known != null &&
            order(payload.revision, known.payload.revision) == Order.OLDER
        // Only what the peer sent us itself is remembered (see above).
        if (!stale && source != Source.CACHED) {
            newest[peerId] = Newest(payload, now(), source == Source.FRAME)
        }

        when (source) {
            Source.FRAME -> {
                // Delivered late: the peer has sent something newer since.
                if (stale) return null
                frames[peerId] = Frame(payload, now(), lifetimeOf(payload))
                return payload
            }
            Source.READ -> {
                // Older than what the peer has sent since: a read a frame
                // overtook, or a stale relayed copy. It changes nothing.
                if (stale) return null
                // Newer than any frame, so the frame's job is done.
                frames.remove(peerId)
                return payload
            }
            Source.CACHED -> {
                val frame = unexpiredFrame(peerId)
                if (frame != null) {
                    // A later frame replaces this one and a later read ends
                    // it, so the frame is the newest payload remembered for
                    // the peer, and a stale payload is never newer than it.
                    if (order(payload.revision, frame.payload.revision) == Order.NEWER) {
                        // Herald holds something newer than the frame.
                        frames.remove(peerId)
                        return payload
                    }
                    // After a hello, report the peer as the frame described it.
                    return if (frame.payload.offline) null else frame.payload
                }
                // Stale implies a known newest payload.
                if (!stale) return payload
                return when {
                    !known.payload.offline -> known.payload
                    // The goodbye has run out: likely a restart whose hello
                    // never arrived, so believe the reading.
                    known.fromFrame -> payload
                    // A fresh read said offline; this older copy is a relay's.
                    else -> null
                }
            }
        }
    }

    @Synchronized
    fun clearAll() {
        frames.clear()
        newest.clear()
    }

    /** How many peers have an entry, expired or not. For tests. */
    @Synchronized
    internal fun trackedPeerCount(): Int = (frames.keys + newest.keys).size

    private fun lifetimeOf(frame: Payload): Long =
        if (frame.offline && frame.deviceKind == StatusPayloadSupplier.DEVICE_KIND_IOS) {
            iphoneGoodbyeTtlMillis
        } else {
            ttlMillis
        }

    private fun unexpiredFrame(peerId: Long): Frame? {
        val entry = frames[peerId] ?: return null
        if (now() - entry.recordedAt > entry.lifetime) {
            frames.remove(peerId)
            return null
        }
        return entry
    }

    private fun unexpiredNewest(peerId: Long): Newest? {
        val entry = newest[peerId] ?: return null
        if (now() - entry.confirmedAt > revisionMemoryMillis) {
            newest.remove(peerId)
            return null
        }
        return entry
    }

    /** Drops expired entries of peers that are no longer looked up. */
    private fun sweepIfDue() {
        val time = now()
        if (time - lastSweep <= revisionMemoryMillis) return
        lastSweep = time
        frames.entries.removeAll { time - it.value.recordedAt > it.value.lifetime }
        newest.entries.removeAll { time - it.value.confirmedAt > revisionMemoryMillis }
    }

    /**
     * Serial-number comparison of 7-bit revisions: [a] is newer than [b] when
     * it is 1-63 steps ahead, older when 65-127 ahead. Null when either is
     * unknown, or when they are exactly half the range apart.
     */
    private fun order(a: Int?, b: Int?): Order? {
        if (a == null || b == null) return null
        val distance = (a - b) and StatusPayloadSupplier.REVISION_MASK
        return when {
            distance == 0 -> Order.SAME
            distance < HALF_RANGE -> Order.NEWER
            distance > HALF_RANGE -> Order.OLDER
            else -> null
        }
    }

    private companion object {
        const val HALF_RANGE = (StatusPayloadSupplier.REVISION_MASK + 1) / 2
    }
}
