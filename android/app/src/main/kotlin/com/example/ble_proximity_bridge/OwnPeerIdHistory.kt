package com.example.ble_proximity_bridge

import android.content.Context

/**
 * The ids this device broadcast as before its current one, kept across
 * launches so [PayloadPipeline] can drop them like the current id. Mirror
 * of OwnPeerIdHistory.swift.
 *
 * Ids are per `BridgeController` in Dart, so a new one comes with every
 * launch and every hot restart. A peer can still hold our payload from an
 * earlier one: Herald for Android keeps a device's record until it has not
 * been updated for 15 minutes (`taskRemoveExpiredDevices`), and when our
 * Bluetooth address has rotated in the meantime it cannot tie that record
 * to us. Its payload sharing relays records updated in the last 5 minutes
 * (`payloadSharingExpiryTimeInterval`) and only skips a payload
 * byte-identical to the one it last read from us, so it hands the old
 * payload back to us as another device's. Without this we would list our
 * own earlier launch as a peer. Herald 2.2.0 for Android only relays to iOS
 * peers, so on Android this keeps the two pipelines mirrors.
 *
 * Remembered for [RETENTION_MILLIS] after the id was replaced, capped at
 * [CAPACITY] ids. Ids are random 31-bit values, so mistaking another
 * device's id for one of ours is not a practical concern. Ids from mock
 * starts are kept too; they were never broadcast, which is harmless.
 *
 * Times are wall-clock milliseconds, the only clock that carries across
 * launches and reboots. A clock set back only keeps ids longer, which the
 * cap bounds; one set forward can expire them early.
 *
 * [noteCurrent] is called on the main thread; [isPrevious] from Herald's
 * threads. Both synchronize, and [isPrevious] never touches storage.
 */
class OwnPeerIdHistory(
    read: () -> String?,
    private val write: (String) -> Unit,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private class Entry(val peerId: Long, val replacedAtMillis: Long)

    private var current: Long? = null
    private val previous = ArrayList<Entry>()

    init {
        read()?.let(::decode)
    }

    /**
     * This device now broadcasts as [peerId]. A different id than last time
     * (in this launch or an earlier one) becomes a previous id.
     */
    fun noteCurrent(peerId: Long) {
        val text = synchronized(this) {
            val nowMillis = now()
            val old = current
            if (old != null && old != peerId) {
                previous.removeAll { it.peerId == old }
                previous.add(Entry(old, nowMillis))
            }
            previous.removeAll { it.peerId == peerId }
            current = peerId
            previous.removeAll { nowMillis - it.replacedAtMillis > RETENTION_MILLIS }
            while (previous.size > CAPACITY) previous.removeAt(0)
            encoded()
        }
        // Outside the lock: Herald's threads call isPrevious meanwhile, and
        // the write is a disk write. Only the main thread writes, so writes
        // stay in order.
        write(text)
    }

    /** Whether [peerId] is one this device broadcast as before its current id, within the retention. */
    fun isPrevious(peerId: Long): Boolean = previousAgeMillis(peerId) != null

    /** How long ago [peerId] stopped being this device's id, if it is a previous one within the retention. */
    @Synchronized
    fun previousAgeMillis(peerId: Long): Long? {
        val entry = previous.lastOrNull { it.peerId == peerId } ?: return null
        val age = now() - entry.replacedAtMillis
        return if (age <= RETENTION_MILLIS) age else null
    }

    /** The previous ids within the retention, oldest first, for the log. */
    @Synchronized
    fun previousIds(): List<Long> {
        val nowMillis = now()
        return previous.filter { nowMillis - it.replacedAtMillis <= RETENTION_MILLIS }.map { it.peerId }
    }

    /** `current|id@millis,id@millis`, ids in decimal; the same format as on iOS. */
    private fun encoded(): String =
        (current?.toString() ?: "") + "|" +
            previous.joinToString(",") { "${it.peerId}@${it.replacedAtMillis}" }

    /**
     * Anything that does not parse is skipped: losing the history only
     * brings back the ghost this guards against, nothing worse.
     */
    private fun decode(text: String) {
        val parts = text.split('|', limit = 2)
        if (parts.size != 2) return
        current = parts[0].toLongOrNull()
        for (entry in parts[1].split(',')) {
            val fields = entry.split('@')
            if (fields.size != 2) continue
            val id = fields[0].toLongOrNull() ?: continue
            val at = fields[1].toLongOrNull() ?: continue
            previous.add(Entry(id, at))
        }
    }

    companion object {
        /**
         * A margin, not a derived bound. Every update to Herald for
         * Android's record of us resets its 15-minute expiry and its
         * 5-minute sharing window, and not only our advertisements do that
         * (any field Herald sets on the record does). On hardware an old id
         * was relayed back about 8 minutes after that launch ended, so
         * something refreshed it after we left; what, is not known. 30
         * minutes is twice the record's expiry counted from the
         * replacement. The drop line logs each id's age, so field logs show
         * how late relays really come.
         */
        const val RETENTION_MILLIS = 30 * 60_000L

        /**
         * Only bounds a clock set back; within the retention it is never
         * reached in practice (a relaunch or hot restart every 28 s).
         * Checking 64 ids per payload costs nothing next to decoding it.
         */
        const val CAPACITY = 64

        private const val PREFS = "bridge"
        private const val KEY = "ownPeerIdHistory"

        /**
         * Backed by SharedPreferences. Written with commit(), not apply():
         * a launch that is killed right after starting must still leave its
         * id behind for the next one. One small write per start. The app
         * sets no backup rules, so Android backup and device transfer copy
         * it; a device restored within 30 minutes would take the old
         * device's last id for one of its own and hide that device if it
         * still runs that launch nearby. Unlikely enough to accept.
         */
        fun forContext(context: Context): OwnPeerIdHistory {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return OwnPeerIdHistory(
                read = { prefs.getString(KEY, null) },
                write = { prefs.edit().putString(KEY, it).commit() },
            )
        }
    }
}
