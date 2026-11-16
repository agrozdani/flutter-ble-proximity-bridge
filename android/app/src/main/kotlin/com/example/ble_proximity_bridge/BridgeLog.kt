package com.example.ble_proximity_bridge

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.heraldprox.herald.sensor.ble.BLESensorConfiguration
import io.heraldprox.herald.sensor.data.SensorLoggerLevel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The native half of the app's logging, used by every Android class. See
 * docs/logging.md; the line format is the one in
 * lib/src/logging/log_line.dart, so Dart, Android and iOS lines read and
 * merge the same way.
 *
 * Each line goes:
 *  - to logcat under the tag [TAG]. `flutter run` shows it, since it prints
 *    every logcat line from the app's process. A stack trace goes out one
 *    line per logcat entry, and a very long line in pieces ([logcatParts]);
 *  - to the log file (files/logs/bridge.log), which also receives Dart's
 *    lines, so it holds the whole run. The previous [KEPT_FILES] - 1 files
 *    are kept (bridge.1.log is the previous launch, or the first part of
 *    this one if it outgrew [MAX_FILE_BYTES]);
 *  - to Dart over the logs event channel, for the in-app log viewer. Lines
 *    logged while Dart is not listening are held (up to [MAX_PENDING]) and
 *    delivered once it subscribes.
 *
 * Writes are synchronous, so the lines that lead up to a crash are on disk
 * when the process dies. Nothing is logged until [start] runs: the JVM unit
 * tests have no android.util.Log and never call it.
 */
object BridgeLog {

    enum class Level(val letter: Char, val priority: Int) {
        DEBUG('D', Log.DEBUG),
        INFO('I', Log.INFO),
        WARN('W', Log.WARN),
        ERROR('E', Log.ERROR),
        ;

        companion object {
            fun parse(name: String?): Level? =
                entries.firstOrNull { it.name.equals(name, ignoreCase = true) }
        }
    }

    const val TAG = "BPB"
    private const val FILE_NAME = "bridge.log"
    private const val MAX_FILE_BYTES = 4L * 1024 * 1024
    private const val KEPT_FILES = 3
    private const val MAX_PENDING = 5_000
    private const val MAX_THREAD_NAME = 24

    /**
     * The longest piece handed to logcat in one entry. logd cuts an entry
     * off at about 4 KB (seen on a Pixel Tablet, Android 17: of a
     * 6086-character line, `flutter run` and logcat had the first 4062).
     * The limit is in bytes; a Kotlin char is at most 3 bytes of UTF-8, or 4
     * for a surrogate pair of two chars, so this many always fit.
     */
    internal const val LOGCAT_MAX_CHARS = 1300

    /**
     * What starts the second and later pieces of a line cut for logcat: an
     * indent, so that they read like a stack trace's lines, and "…", so
     * that tool/devlogs.dart can tell them from one and join them back onto
     * their line (a line in a capture then matches the same line in the log
     * file). Its 7 bytes leave each piece well inside logd's limit.
     */
    internal const val LOGCAT_PIECE_PREFIX = "    \u2026"

    /** Lines below this level are dropped; set from Dart (`configure`). */
    @Volatile
    var minLevel = Level.DEBUG
        private set

    /** Herald's own log level, applied to every Herald host we build. */
    @Volatile
    var heraldLevel = SensorLoggerLevel.off
        private set

    @Volatile
    private var started = false

    // Guards the file and the lines waiting for Dart.
    private val lock = Any()
    private var logDir: File? = null
    private var out: FileOutputStream? = null
    private var fileBytes = 0L
    private val pending = ArrayDeque<String>()
    private var pendingDropped = 0
    private var dartSink: EventChannel.EventSink? = null
    private var drainPosted = false

    private val mainThread by lazy { Handler(Looper.getMainLooper()) }
    private val timeFormat = object : ThreadLocal<SimpleDateFormat>() {
        override fun initialValue() = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)
    }

    /** The file being written, once [start] has run. */
    val currentFile: File?
        get() = logDir?.let { File(it, FILE_NAME) }

    /**
     * Opens the log file and writes the header. Called by MainActivity and
     * by ProximityService, whichever the process creates first; later calls
     * do nothing.
     */
    fun start(context: Context) {
        synchronized(lock) {
            if (started) return
            val dir = File(context.filesDir, "logs")
            dir.mkdirs()
            logDir = dir
            rotate(dir)
            out = openFile(dir)
            started = true
        }
        installCrashHandler()
        i("log", "==== native log start pid=${Process.myPid()} ${appVersion(context)}")
        i(
            "log",
            "device ${Build.MANUFACTURER} ${Build.MODEL} (${Build.DEVICE}) " +
                "Android ${Build.VERSION.RELEASE} SDK ${Build.VERSION.SDK_INT}",
        )
        i("log", "file ${currentFile?.absolutePath}")
    }

    /** Applies the levels Dart asked for (see LoggingSetup in Dart). */
    fun configure(level: Level?, herald: SensorLoggerLevel?) {
        if (level != null) minLevel = level
        if (herald != null) {
            heraldLevel = herald
            // Herald reads it on every log call, so this applies at once.
            BLESensorConfiguration.logLevel = herald
        }
        i("log", "configured level=${minLevel.name.lowercase()} herald=${heraldLevel.name}")
    }

    fun isEnabled(level: Level): Boolean = started && level >= minLevel

    /** Debug lines take a lambda so a disabled level costs no formatting. */
    inline fun d(component: String, message: () -> String) {
        if (isEnabled(Level.DEBUG)) log(Level.DEBUG, component, message(), null)
    }

    fun i(component: String, message: String) = log(Level.INFO, component, message, null)

    fun w(component: String, message: String, error: Throwable? = null) =
        log(Level.WARN, component, message, error)

    fun e(component: String, message: String, error: Throwable? = null) =
        log(Level.ERROR, component, message, error)

    fun log(level: Level, component: String, message: String, error: Throwable?) {
        if (!isEnabled(level)) return
        val text = if (error == null) {
            message
        } else {
            "$message: $error\n" + Log.getStackTraceString(error).trimEnd().prependIndent("    ")
        }
        val line = "${timeFormat.get()!!.format(Date())} ${level.letter} native.$component " +
            "[${threadName()}] $text"
        val parts = logcatParts(line)
        synchronized(lock) {
            // Under the lock, so that another thread's line cannot land
            // between the lines of a stack trace, and logcat has the lines
            // in the file's order. Nothing waits here: liblog writes to logd
            // on a non-blocking socket and drops the entry when logd is
            // overloaded (AOSP main, system/logging/liblog/logd_writer.cpp).
            for (part in parts) Log.println(level.priority, TAG, part)
            writeLine(line)
            queueForDart(line)
        }
    }

    /**
     * [line] as the entries it is sent to logcat in: one per line of a
     * multi-line message (logcat prints them that way in any case), and a
     * line longer than [LOGCAT_MAX_CHARS] in pieces, the later ones starting
     * with [LOGCAT_PIECE_PREFIX]. The log file and Dart get the line whole.
     */
    internal fun logcatParts(line: String): List<String> = line.split('\n').flatMap { part ->
        if (part.length <= LOGCAT_MAX_CHARS) {
            listOf(part)
        } else {
            part.chunked(LOGCAT_MAX_CHARS).mapIndexed { index, piece ->
                if (index == 0) piece else "$LOGCAT_PIECE_PREFIX$piece"
            }
        }
    }

    /**
     * Appends lines Dart already formatted to the file. They are not sent to
     * logcat (Dart printed them, under the `flutter` tag) or back to Dart.
     */
    fun writeFromDart(lines: List<String>) {
        if (!started) return
        synchronized(lock) { lines.forEach(::writeLine) }
    }

    /** The logs event channel's sink; main thread only. */
    fun attachDart(sink: EventChannel.EventSink?) {
        synchronized(lock) {
            dartSink = sink
            if (sink != null) scheduleDrain()
        }
    }

    // ----- File ------------------------------------------------------------------

    private fun writeLine(line: String) {
        val stream = out ?: return
        val bytes = (line + "\n").toByteArray(Charsets.UTF_8)
        try {
            stream.write(bytes)
            fileBytes += bytes.size
            if (fileBytes > MAX_FILE_BYTES) {
                stream.close()
                val dir = logDir ?: return
                rotate(dir)
                out = openFile(dir)
                out?.write("${timeFormat.get()!!.format(Date())} I native.log [log] continued from bridge.1.log\n".toByteArray())
            }
        } catch (e: IOException) {
            Log.w(TAG, "Log file write failed; file logging stops", e)
            out = null
        }
    }

    /** bridge.log → bridge.1.log → bridge.2.log; the oldest is dropped. */
    private fun rotate(dir: File) {
        File(dir, nameFor(KEPT_FILES - 1)).delete()
        for (index in KEPT_FILES - 2 downTo 0) {
            val from = File(dir, nameFor(index))
            if (from.exists()) from.renameTo(File(dir, nameFor(index + 1)))
        }
    }

    private fun nameFor(index: Int) = if (index == 0) FILE_NAME else "bridge.$index.log"

    private fun openFile(dir: File): FileOutputStream? = try {
        fileBytes = 0
        FileOutputStream(File(dir, FILE_NAME), true)
    } catch (e: IOException) {
        Log.w(TAG, "Cannot open the log file; logging to logcat only", e)
        null
    }

    // ----- Dart ------------------------------------------------------------------

    /** Call with [lock] held. */
    private fun queueForDart(line: String) {
        pending.addLast(line)
        if (pending.size > MAX_PENDING) {
            pending.removeFirst()
            pendingDropped++
        }
        scheduleDrain()
    }

    /** Call with [lock] held. */
    private fun scheduleDrain() {
        if (dartSink == null || drainPosted || pending.isEmpty()) return
        drainPosted = true
        mainThread.post(::drain)
    }

    /** Sends everything pending in one batch. Runs on the main thread. */
    private fun drain() {
        val sink: EventChannel.EventSink
        val batch: List<String>
        synchronized(lock) {
            drainPosted = false
            sink = dartSink ?: return
            if (pending.isEmpty()) return
            batch = ArrayList<String>(pending.size + 1).apply {
                if (pendingDropped > 0) {
                    add("${timeFormat.get()!!.format(Date())} W native.log [main] " +
                        "$pendingDropped earlier lines did not fit while Dart was not listening")
                    pendingDropped = 0
                }
                addAll(pending)
            }
            pending.clear()
        }
        try {
            sink.success(batch)
        } catch (e: Exception) {
            // The engine went away; the lines are still in logcat and the file.
            Log.w(TAG, "Log sink rejected a batch; detaching it", e)
            synchronized(lock) { if (dartSink === sink) dartSink = null }
        }
    }

    // ----- Helpers ---------------------------------------------------------------

    private fun threadName(): String {
        val name = Thread.currentThread().name
        return if (name.length > MAX_THREAD_NAME) name.takeLast(MAX_THREAD_NAME) else name
    }

    private fun appVersion(context: Context): String = try {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        val debuggable = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        "app=${info.versionName}+$code debuggable=$debuggable"
    } catch (e: PackageManager.NameNotFoundException) {
        "app=unknown"
    }

    /** Logs an uncaught exception before Android's own handler kills the app. */
    private fun installCrashHandler() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                e("crash", "uncaught exception on thread ${thread.name}", error)
            } catch (_: Throwable) {
                // Never let logging stand in the way of the crash report.
            }
            previous?.uncaughtException(thread, error)
        }
    }
}

/** A device kind from the payload, for the log: `ios`, `android` or the code. */
fun deviceKindName(kind: Int?): String = when (kind) {
    StatusPayloadSupplier.DEVICE_KIND_IOS -> "ios"
    StatusPayloadSupplier.DEVICE_KIND_ANDROID -> "android"
    else -> "dev=$kind"
}

/**
 * A peer id as every log line writes it: upper-case hex, at least 8 digits,
 * negative ids as their 64-bit two's complement (same as Dart's peerHex).
 */
fun peerHex(id: Long): String =
    java.lang.Long.toHexString(id).uppercase(Locale.US).padStart(8, '0')
