package com.example.ble_proximity_bridge

import android.os.SystemClock
import java.util.Locale

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

    /** Why [resolveExplained] decided what it did; logged by the pipeline. */
    enum class Verdict(val description: String) {
        FRAME_RECORDED("frame recorded"),
        FRAME_LATE("dropped: older than the newest revision"),
        READ_ACCEPTED("accepted"),
        READ_ENDS_FRAME("accepted; ends the frame's override"),
        READ_STALE("dropped: older than the newest revision"),
        CACHED_ACCEPTED("accepted"),
        CACHED_NEWER_THAN_FRAME("accepted: newer than the frame, which it ends"),
        CACHED_HIDDEN_BY_GOODBYE("ignored: the peer's goodbye frame outvotes it"),
        CACHED_REPLACED_BY_HELLO("replaced by the peer's hello frame"),
        CACHED_REPLACED_BY_NEWEST("replaced by the newest payload (it is older)"),
        CACHED_BELIEVED_AFTER_GOODBYE(
            "accepted: older, but the goodbye ran out (likely a restart whose hello was lost)",
        ),
        CACHED_DROPPED_AFTER_OFFLINE_READ("ignored: older than a read that said offline"),
        ;

        /** The name in the stats line, as on iOS: `cachedAccepted`. */
        val key: String
            get() = name.lowercase().split('_').mapIndexed { index, part ->
                if (index == 0) part else part.replaceFirstChar { it.uppercase() }
            }.joinToString("")
    }

    /**
     * What [resolveExplained] returns: the payload to act on (null: ignore
     * it), why, and what it was weighed against, for the log.
     */
    class Resolution(val payload: Payload?, val verdict: Verdict, val context: String)

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
    fun resolve(peerId: Long, source: Source, payload: Payload): Payload? =
        resolveExplained(peerId, source, payload).payload

    /** [resolve], plus why. */
    @Synchronized
    fun resolveExplained(peerId: Long, source: Source, payload: Payload): Resolution {
        sweepIfDue()
        val known = unexpiredNewest(peerId)
        val stale = known != null &&
            order(payload.revision, known.payload.revision) == Order.OLDER
        // What this payload is weighed against, before anything changes.
        val context = describe(known, peekFrame(peerId))
        // Only what the peer sent us itself is remembered (see above).
        if (!stale && source != Source.CACHED) {
            newest[peerId] = Newest(payload, now(), source == Source.FRAME)
        }

        when (source) {
            Source.FRAME -> {
                // Delivered late: the peer has sent something newer since.
                if (stale) return Resolution(null, Verdict.FRAME_LATE, context)
                frames[peerId] = Frame(payload, now(), lifetimeOf(payload))
                return Resolution(payload, Verdict.FRAME_RECORDED, context)
            }
            Source.READ -> {
                // Older than what the peer has sent since: a read a frame
                // overtook, or a stale relayed copy. It changes nothing.
                if (stale) return Resolution(null, Verdict.READ_STALE, context)
                // Newer than any frame, so the frame's job is done.
                val hadFrame = peekFrame(peerId) != null
                frames.remove(peerId)
                val verdict = if (hadFrame) Verdict.READ_ENDS_FRAME else Verdict.READ_ACCEPTED
                return Resolution(payload, verdict, context)
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
                        return Resolution(payload, Verdict.CACHED_NEWER_THAN_FRAME, context)
                    }
                    // After a hello, report the peer as the frame described it.
                    return if (frame.payload.offline) {
                        Resolution(null, Verdict.CACHED_HIDDEN_BY_GOODBYE, context)
                    } else {
                        Resolution(frame.payload, Verdict.CACHED_REPLACED_BY_HELLO, context)
                    }
                }
                // Stale implies a known newest payload.
                if (!stale) return Resolution(payload, Verdict.CACHED_ACCEPTED, context)
                return when {
                    !known.payload.offline ->
                        Resolution(known.payload, Verdict.CACHED_REPLACED_BY_NEWEST, context)
                    // The goodbye has run out: likely a restart whose hello
                    // never arrived, so believe the reading.
                    known.fromFrame ->
                        Resolution(payload, Verdict.CACHED_BELIEVED_AFTER_GOODBYE, context)
                    // A fresh read said offline; this older copy is a relay's.
                    else -> Resolution(null, Verdict.CACHED_DROPPED_AFTER_OFFLINE_READ, context)
                }
            }
        }
    }

    /**
     * What is remembered for each peer that still has an unexpired entry,
     * for the periodic stats line.
     */
    @Synchronized
    fun snapshot(): Map<Long, String> {
        val ids = frames.keys + newest.keys
        return ids.associateWith { describe(peekNewest(it), peekFrame(it)) }
            .filterValues { it != NOTHING_REMEMBERED }
    }

    @Synchronized
    fun clearAll() {
        frames.clear()
        newest.clear()
    }

    /** How many peers have an entry, expired or not. For tests. */
    @Synchronized
    internal fun trackedPeerCount(): Int = (frames.keys + newest.keys).size

    /** E.g. `newest rev=17 online (read 3.2s ago) | frame goodbye rev=18 (1.8s left)`. */
    private fun describe(known: Newest?, frame: Frame?): String {
        if (known == null && frame == null) return NOTHING_REMEMBERED
        val time = now()
        val parts = mutableListOf<String>()
        if (known != null) {
            val origin = if (known.fromFrame) "frame" else "read"
            parts += "newest rev=${known.payload.revision ?: "-"} " +
                "${if (known.payload.offline) "offline" else "online"} " +
                "($origin ${seconds(time - known.confirmedAt)} ago)"
        }
        if (frame != null) {
            parts += "frame ${if (frame.payload.offline) "goodbye" else "hello"} " +
                "rev=${frame.payload.revision ?: "-"} " +
                "(${seconds(frame.lifetime - (time - frame.recordedAt))} left)"
        }
        return parts.joinToString(" | ")
    }

    private fun seconds(millis: Long) = String.format(Locale.US, "%.1fs", millis / 1000.0)

    private fun lifetimeOf(frame: Payload): Long =
        if (frame.offline && frame.deviceKind == StatusPayloadSupplier.DEVICE_KIND_IOS) {
            iphoneGoodbyeTtlMillis
        } else {
            ttlMillis
        }

    // Lookups for the log: like the two below, but they leave expired
    // entries in place, so logging never changes the state.
    private fun peekFrame(peerId: Long): Frame? =
        frames[peerId]?.takeIf { now() - it.recordedAt <= it.lifetime }

    private fun peekNewest(peerId: Long): Newest? =
        newest[peerId]?.takeIf { now() - it.confirmedAt <= revisionMemoryMillis }

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
        const val NOTHING_REMEMBERED = "nothing remembered"
    }
}
