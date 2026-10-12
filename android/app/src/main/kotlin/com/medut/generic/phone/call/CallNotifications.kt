package com.medut.generic.phone.call

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import com.medut.generic.phone.CallSnapshot
import com.medut.generic.phone.MainActivity
import com.medut.generic.phone.R

object CallNotifications {
    const val CH_INCOMING = "medut_incoming_call"
    const val CH_ONGOING = "medut_ongoing_call"
    const val CH_SERVICE = "medut_service"
    const val CH_MISSED = "medut_missed_calls"
    const val CH_MESSAGES = "medut_messages"

    const val ID_INCOMING = 1001
    const val ID_SERVICE = 1002
    const val ID_MISSED = 1003

    private const val GREEN = 0xFF1A7F37.toInt()

    fun createChannels(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannels(listOf(
            // Silent: Ringer plays the ringtone, so the channel must not double it.
            // Rings through Do not disturb, like the phone's own calls.
            NotificationChannel(CH_INCOMING, "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply {
                setSound(null, null)
                enableVibration(false)
                setBypassDnd(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            },
            NotificationChannel(CH_ONGOING, "Ongoing call", NotificationManager.IMPORTANCE_LOW).apply {
                setSound(null, null)
                enableVibration(false)
            },
            NotificationChannel(CH_SERVICE, "Stay reachable", NotificationManager.IMPORTANCE_MIN).apply {
                description = "Keeps your SIP accounts registered in the background"
                setShowBadge(false)
            },
            // High: a missed call or a message pops up as a heads-up.
            NotificationChannel(CH_MISSED, "Missed calls", NotificationManager.IMPORTANCE_HIGH),
            NotificationChannel(CH_MESSAGES, "Messages", NotificationManager.IMPORTANCE_HIGH),
        ))
    }

    private fun flags() = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

    private fun actionIntent(context: Context, action: String, req: Int): PendingIntent =
        PendingIntent.getBroadcast(
            context, req,
            Intent(context, CallActionReceiver::class.java).setAction(action),
            flags(),
        )

    private fun callScreenIntent(context: Context, req: Int, answer: Boolean = false): PendingIntent =
        PendingIntent.getActivity(
            context, req,
            CallActivity.intent(context).putExtra(CallActivity.EXTRA_ANSWER, answer),
            flags(),
        )

    private fun person(s: CallSnapshot): Person =
        Person.Builder().setName(s.title.ifBlank { "Unknown" }).setImportant(true).build()

    fun showIncoming(context: Context, s: CallSnapshot) {
        if (s.phase != "incoming") return
        val text = if (s.account.isNotBlank()) s.label("incomingOn", "Incoming call") + " · " + s.account
        else s.label("incomingCall", "Incoming call")
        val n = NotificationCompat.Builder(context, CH_INCOMING)
            .setSmallIcon(R.drawable.ic_stat_medut)
            .setContentTitle(s.title)
            .setContentText(text)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(callScreenIntent(context, 10))
            .setFullScreenIntent(callScreenIntent(context, 11), true)
            .setStyle(
                NotificationCompat.CallStyle.forIncomingCall(
                    person(s),
                    actionIntent(context, CallActionReceiver.DECLINE, 12),
                    callScreenIntent(context, 13, answer = true),
                ),
            )
            .build()
        notify(context, ID_INCOMING, n)
    }

    fun cancelIncoming(context: Context) {
        NotificationManagerCompat.from(context).cancel(ID_INCOMING)
    }

    /**
     * The green "call in progress" card, posted by MedutService as its
     * foreground notification: running timer, Mute, Speaker, Hang up.
     * "Calling…" with no timer until the call connects.
     */
    fun ongoing(context: Context, s: CallSnapshot): Notification {
        val connecting = s.startedAt <= 0
        val b = NotificationCompat.Builder(context, CH_ONGOING)
            .setSmallIcon(R.drawable.ic_stat_medut)
            .setContentTitle(s.title)
            .setContentText(if (connecting) s.label("calling", "Calling…") else s.status.ifBlank { s.account })
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setColorized(true)
            .setColor(GREEN)
            .setContentIntent(callScreenIntent(context, 20))
            .setStyle(
                NotificationCompat.CallStyle.forOngoingCall(
                    person(s),
                    actionIntent(context, CallActionReceiver.HANGUP, 21),
                ),
            )
            .addAction(
                R.drawable.ic_mic_off,
                if (s.muted) s.label("unmute", "Unmute") else s.label("mute", "Mute"),
                actionIntent(context, CallActionReceiver.TOGGLE_MUTE, 22),
            )
            .addAction(
                R.drawable.ic_speaker,
                s.label("speaker", "Speaker"),
                actionIntent(context, CallActionReceiver.TOGGLE_SPEAKER, 23),
            )
        if (connecting) {
            b.setShowWhen(false)
        } else {
            b.setWhen(s.startedAt).setUsesChronometer(true).setShowWhen(true)
        }
        return b.build()
    }

    /** Idle foreground notification while staying registered in the background. */
    fun service(context: Context, title: String, text: String): Notification =
        NotificationCompat.Builder(context, CH_SERVICE)
            .setSmallIcon(R.drawable.ic_stat_medut)
            .setContentTitle(title)
            .setContentText(text)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(
                PendingIntent.getActivity(
                    context, 30,
                    Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    flags(),
                ),
            )
            .build()

    /** One notification for all unseen missed calls, replaced on every new miss. */
    fun showMissed(context: Context, count: Int, latest: String, title: String) {
        val n = NotificationCompat.Builder(context, CH_MISSED)
            .setSmallIcon(R.drawable.ic_stat_medut)
            .setContentTitle(title)
            .setContentText(latest)
            .setNumber(count)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MISSED_CALL)
            .setAutoCancel(true)
            .setContentIntent(
                PendingIntent.getActivity(
                    context, 31,
                    Intent(context, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        .putExtra(MainActivity.EXTRA_ROUTE, "activity"),
                    flags(),
                ),
            )
            .build()
        notify(context, ID_MISSED, n)
    }

    fun cancelMissed(context: Context) {
        NotificationManagerCompat.from(context).cancel(ID_MISSED)
    }

    /** A SIP MESSAGE; one notification per conversation. */
    fun showMessage(context: Context, peer: String, title: String, body: String) {
        val n = NotificationCompat.Builder(context, CH_MESSAGES)
            .setSmallIcon(R.drawable.ic_stat_medut)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setContentIntent(
                PendingIntent.getActivity(
                    context, 40 + (peer.hashCode() and 0xFFFF),
                    Intent(context, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        .putExtra(MainActivity.EXTRA_ROUTE, "chat:$peer"),
                    flags(),
                ),
            )
            .build()
        notify(context, 3000 + (peer.hashCode() and 0xFFFF), n)
    }

    private fun notify(context: Context, id: Int, n: Notification) {
        try {
            NotificationManagerCompat.from(context).notify(id, n)
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS not granted; the in-app screens still work.
        }
    }
}
