package com.medut.generic.phone.engine

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log

/**
 * Writes finished calls and SIP messages into `medut.db`, the database the
 * Flutter history screens read (lib/core/db.dart). Dart owns the schema and
 * its migrations; the app is opened before any account exists, so the file is
 * always there by the time a call can be written. Rows are the columns of
 * `CallRecord.toRow()` / `ChatMessage.toRow()`.
 */
class HistoryWriter(private val context: Context) {
    private var db: SQLiteDatabase? = null

    @Synchronized
    private fun open(): SQLiteDatabase? {
        db?.takeIf { it.isOpen }?.let { return it }
        val path = context.getDatabasePath("medut.db")
        if (!path.exists()) {
            Log.w(TAG, "medut.db not created yet; nothing written")
            return null
        }
        return try {
            SQLiteDatabase.openDatabase(path.path, null, SQLiteDatabase.OPEN_READWRITE).also {
                // sqflite holds its own connection to the same file.
                it.rawQuery("PRAGMA busy_timeout = 3000", null).use { c -> c.moveToFirst() }
                if (it.version < 4) Log.w(TAG, "medut.db is at schema ${it.version}, expected 4")
                db = it
            }
        } catch (e: Exception) {
            Log.e(TAG, "open medut.db", e)
            null
        }
    }

    fun addCall(row: ContentValues): Boolean = write { it.insert("calls", null, row) >= 0 }

    fun addMessage(accountId: String, peer: String, body: String, outgoing: Boolean, at: Long = System.currentTimeMillis()): Boolean =
        write {
            it.insert("messages", null, ContentValues().apply {
                put("account_id", accountId)
                put("peer", peer)
                put("body", body)
                put("outgoing", if (outgoing) 1 else 0)
                put("at", at)
                put("read", if (outgoing) 1 else 0)
            }) >= 0
        }

    /** Missed calls since [since] (ms), for the missed-call notification. */
    fun missedSince(since: Long): Int = read(0) {
        it.rawQuery("SELECT COUNT(*) FROM calls WHERE result='missed' AND started_at > ?", arrayOf(since.toString())).use { c ->
            if (c.moveToFirst()) c.getInt(0) else 0
        }
    }

    /** Two calls from the same number within 3 minutes: "repeat caller". */
    fun calledRecently(number: String): Boolean = read(false) {
        val since = System.currentTimeMillis() - 3 * 60 * 1000
        it.rawQuery("SELECT COUNT(*) FROM calls WHERE number = ? AND started_at > ?", arrayOf(number, since.toString())).use { c ->
            c.moveToFirst() && c.getInt(0) > 0
        }
    }

    /** Numbers of the most recent calls, newest first (presence targets). */
    fun recentNumbers(limit: Int = 300): List<String> = read(emptyList()) {
        it.rawQuery("SELECT number FROM calls ORDER BY started_at DESC LIMIT $limit", null).use { c ->
            buildList { while (c.moveToNext()) add(c.getString(0) ?: "") }
        }
    }

    private fun write(block: (SQLiteDatabase) -> Boolean): Boolean = try {
        open()?.let(block) ?: false
    } catch (e: Exception) {
        Log.e(TAG, "write", e)
        false
    }

    private fun <T> read(fallback: T, block: (SQLiteDatabase) -> T): T = try {
        open()?.let(block) ?: fallback
    } catch (e: Exception) {
        Log.e(TAG, "read", e)
        fallback
    }

    private companion object {
        const val TAG = "MedutHistory"
    }
}
