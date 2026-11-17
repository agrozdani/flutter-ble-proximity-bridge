package com.example.ble_proximity_bridge

import android.content.Context

/**
 * The ids this device broadcast as before its current one, kept across
 * launches so [PayloadPipeline] can drop them like the current id. Mirror
 * of OwnPeerIdHistory.swift.
 *
 * Ids are per launch (`BridgeController` in Dart). A peer can still hold
 * our payload from an earlier launch: Herald for Android keeps a device's
 * record for up to 15 minutes after its last update
 * (`taskRemoveExpiredDevices`), and when our Bluetooth address has rotated
 * in the meantime it cannot tie that record to us. Its payload sharing then
 * relays the old payload back to us as another device's, and only skips a
 * payload byte-identical to our current one. Without this we would list our
 * own earlier launch as a peer. Herald 2.2.0 for Android only relays to iOS
 * peers, so on Android this keeps the two pipelines mirrors.
 *
 * Remembered for [RETENTION_MILLIS] after the id was replaced, capped at
 * [CAPACITY] ids. Ids are random 31-bit values, so mistaking another
 * device's id for one of ours is not a practical concern.
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
    @Synchronized
    fun noteCurrent(peerId: Long) {
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
        write(encoded())
    }

    /** Whether [peerId] is one this device broadcast as before its current id, within the retention. */
    @Synchronized
    fun isPrevious(peerId: Long): Boolean {
        val nowMillis = now()
        return previous.any { it.peerId == peerId && nowMillis - it.replacedAtMillis <= RETENTION_MILLIS }
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
         * Twice Herald for Android's 15-minute device expiry. The record
         * ages from the old launch's last advertisement, which is before the
         * id is replaced here, so 15 minutes would already be enough; the
         * rest is slack.
         */
        const val RETENTION_MILLIS = 30 * 60_000L

        /** Enough for a relaunch every two minutes for the whole retention. */
        const val CAPACITY = 16

        private const val PREFS = "bridge"
        private const val KEY = "ownPeerIdHistory"

        /**
         * Backed by SharedPreferences. Written with commit(), not apply():
         * a launch that is killed right after starting must still leave its
         * id behind for the next one. One small write per start.
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
