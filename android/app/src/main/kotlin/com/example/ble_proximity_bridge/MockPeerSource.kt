package com.example.ble_proximity_bridge

import android.os.Handler
import android.os.Looper
import kotlin.random.Random

/**
 * Fakes peer sightings so the whole bridge can run on an emulator with no
 * Bluetooth hardware. It uses the same callback as the real BLE path, so
 * everything downstream behaves the same.
 */
class MockPeerSource(
    private val onSighting: (
        peerId: Long,
        status: Int,
        color: Int,
        deviceKind: Int,
        rssi: Double,
    ) -> Unit,
) {
    private companion object {
        const val TICK_MILLIS = 1_000L
        const val RSSI_FLOOR = -95.0
        const val RSSI_CEILING = -40.0
        const val STATUS_CHANGE_PROBABILITY = 0.03
        const val STATUS_COUNT = 4
    }

    private data class MockPeer(
        val id: Long,
        var status: Int,
        val color: Int,
        val deviceKind: Int,
        var rssi: Double,
    )

    // One "iPhone" up close, two "Androids" further out. RSSI drifts around
    // so the distance buckets visibly change.
    private val peers = listOf(
        MockPeer(id = 0x51C0FFEE, status = 0, color = 1, deviceKind = 0, rssi = -50.0),
        MockPeer(id = 0x0B5EAFE7, status = 2, color = 3, deviceKind = 1, rssi = -72.0),
        MockPeer(id = 0xCAFED00D, status = 1, color = 4, deviceKind = 1, rssi = -86.0),
    )

    private val handler = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            emitAll()
            handler.postDelayed(this, TICK_MILLIS)
        }
    }

    fun start() {
        handler.post(tick)
    }

    fun stop() {
        handler.removeCallbacks(tick)
    }

    private fun emitAll() {
        for (peer in peers) {
            peer.rssi = (peer.rssi + Random.nextDouble(-3.0, 3.0))
                .coerceIn(RSSI_FLOOR, RSSI_CEILING)
            if (Random.nextDouble() < STATUS_CHANGE_PROBABILITY) {
                peer.status = Random.nextInt(STATUS_COUNT)
            }
            onSighting(peer.id, peer.status, peer.color, peer.deviceKind, peer.rssi)
        }
    }
}
