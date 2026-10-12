package com.medut.generic.phone.call

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.GridLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import com.medut.generic.phone.CallSnapshot
import com.medut.generic.phone.CallState
import com.medut.generic.phone.MainActivity
import com.medut.generic.phone.NativeBridge
import com.medut.generic.phone.R

/**
 * Native ringing + in-call screen (design E). Plain Views, built in code, so it
 * paints in one frame on a cold answer and over the lock screen. It holds no
 * call state of its own: it renders [CallState.latest] and sends every tap to
 * Dart through [NativeBridge].
 */
class CallActivity : Activity() {

    private class Palette(dark: Boolean) {
        val bg = if (dark) 0xFF0D1014.toInt() else 0xFFF6F8FA.toInt()
        val surface = if (dark) 0xFF14181E.toInt() else 0xFFFFFFFF.toInt()
        val surface2 = if (dark) 0xFF1B2027.toInt() else 0xFFEEF1F5.toInt()
        val border = if (dark) 0xFF2A313A.toInt() else 0xFFD8DEE6.toInt()
        val text = if (dark) 0xFFE8EDF3.toInt() else 0xFF1C2128.toInt()
        val text2 = if (dark) 0xFF9AA4B2.toInt() else 0xFF5A6573.toInt()
        val accent = if (dark) 0xFF4493F8.toInt() else 0xFF1F6FEB.toInt()
        val accentSoft = if (dark) 0x294493F8 else 0xFFDDEBFF.toInt()
        val success = if (dark) 0xFF3FB950.toInt() else 0xFF1A7F37.toInt()
        val successSoft = if (dark) 0x1F3FB950 else 0xFFDAF5E1.toInt()
        val onSuccess = if (dark) 0xFF0D1014.toInt() else 0xFFFFFFFF.toInt()
        val danger = if (dark) 0xFFF85149.toInt() else 0xFFCF222E.toInt()
        val warn = if (dark) 0xFFD29922.toInt() else 0xFF9A6700.toInt()
        val warnSoft = if (dark) 0x24D29922 else 0xFFFFF3D1.toInt()
    }

    private val ui = Handler(Looper.getMainLooper())
    private var p = Palette(false)
    private var paletteDark: Boolean? = null
    private var snap = CallSnapshot(emptyMap())
    private var detailsOpen = false
    private var keypadOpen = false
    private var dtmfTyped = ""
    private var proximity: PowerManager.WakeLock? = null
    private var secondAction = "swap"

    private lateinit var root: FrameLayout

    // Incoming
    private lateinit var incoming: LinearLayout
    private lateinit var inAccount: TextView
    private lateinit var inAvatar: TextView
    private lateinit var inName: TextView
    private lateinit var inNumber: TextView
    private lateinit var inBusy: TextView
    private lateinit var inMessage: TextView
    private lateinit var inDecline: LinearLayout
    private lateinit var inAnswer: LinearLayout

    // In call
    private lateinit var call: LinearLayout
    private lateinit var minimize: ImageView
    private lateinit var account: TextView
    private lateinit var mosPill: LinearLayout
    private lateinit var qualityBars: QualityBars
    private lateinit var qualityWord: TextView
    private lateinit var mosText: TextView
    private lateinit var secondBanner: LinearLayout
    private lateinit var secondText: TextView
    private lateinit var secondSwap: TextView
    private lateinit var avatar: TextView
    private lateinit var name: TextView
    private lateinit var status: TextView
    private lateinit var timer: TextView
    private lateinit var details: LinearLayout
    private lateinit var detailsTitle: TextView
    private lateinit var detailsGrid: GridLayout
    private lateinit var hangup: ImageView
    private val controls = mutableMapOf<String, Pair<ImageView, TextView>>()

    // Keypad
    private lateinit var keypad: LinearLayout
    private lateinit var keypadDigits: TextView
    private lateinit var keypadHide: TextView
    private val keypadKeys = mutableListOf<TextView>()

    private val listener: (CallSnapshot) -> Unit = { s -> ui.post { render(s) } }

    private val ticker = object : Runnable {
        override fun run() {
            updateTimer()
            ui.postDelayed(this, 1000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showOverLockScreen(true)
        buildViews()
        setContentView(root)
        isShowing = true
        CallState.addListener(listener)
        handleAnswerExtra(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleAnswerExtra(intent)
    }

    override fun onResume() {
        super.onResume()
        ui.post(ticker)
    }

    override fun onPause() {
        ui.removeCallbacks(ticker)
        super.onPause()
    }

    override fun onDestroy() {
        CallState.removeListener(listener)
        setProximity(false)
        isShowing = false
        super.onDestroy()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // Back leaves the call running and shows the app, like the system dialer.
        if (keypadOpen) {
            keypadOpen = false
            render(snap)
            return
        }
        MainActivity.open(this)
    }

    private fun handleAnswerExtra(intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_ANSWER, false) == true) {
            intent.removeExtra(EXTRA_ANSWER)
            Ringer.stop()
            CallNotifications.cancelIncoming(this)
            NativeBridge.action("answer")
        }
    }

    @Suppress("DEPRECATION")
    private fun showOverLockScreen(on: Boolean) {
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            val f = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(f) else window.clearFlags(f)
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    // ── Rendering ────────────────────────────────────────────────────────────

    private fun render(s: CallSnapshot) {
        snap = s
        if (!s.isLive) {
            setProximity(false)
            showOverLockScreen(false)
            finish()
            return
        }
        if (paletteDark != s.dark) {
            paletteDark = s.dark
            p = Palette(s.dark)
            applyPalette()
        }
        root.layoutDirection = if (s.rtl) View.LAYOUT_DIRECTION_RTL else View.LAYOUT_DIRECTION_LTR

        val isIncoming = s.phase == "incoming"
        incoming.visibility = if (isIncoming) View.VISIBLE else View.GONE
        call.visibility = if (!isIncoming && !keypadOpen) View.VISIBLE else View.GONE
        keypad.visibility = if (!isIncoming && keypadOpen) View.VISIBLE else View.GONE

        val initials = initials(s.title)
        if (isIncoming) {
            inAccount.text = if (s.account.isNotBlank()) s.label("incomingOn", "Incoming on") + " " + s.account
            else s.label("incomingCall", "Incoming call")
            inAvatar.text = initials
            inName.text = s.title
            inNumber.text = if (s.name.isNotBlank()) s.number else ""
            inBusy.text = s.label("busy", "Busy")
            inMessage.text = s.label("message", "Message")
            (inDecline.getChildAt(1) as TextView).text = s.label("decline", "Decline")
            (inAnswer.getChildAt(1) as TextView).text = s.label("answer", "Answer")
            setProximity(false)
            return
        }

        account.text = s.account
        avatar.text = initials
        name.text = s.title
        status.text = s.status.ifBlank { s.number }
        updateTimer()

        // Quality pill: Echo's 3 bars + word, MOS beside it, tap for details.
        if (s.qualityWord.isNotBlank()) {
            mosPill.visibility = View.VISIBLE
            val fg = when (s.qualityLevel) {
                4, 3 -> p.success
                2 -> p.warn
                1 -> p.danger
                else -> p.text2
            }
            mosPill.background = pill(fg and 0x00FFFFFF or 0x1F000000, 16f)
            qualityBars.setQuality(s.qualityLevel, fg, p.text2 and 0x00FFFFFF or 0x40000000)
            qualityWord.text = s.qualityWord
            qualityWord.setTextColor(fg)
            mosText.text = (if (s.mos.isNotBlank()) s.mos + " " else "") + if (detailsOpen) "▴" else "▾"
            mosText.setTextColor(fg)
        } else {
            mosPill.visibility = View.INVISIBLE
        }

        // Details card
        val rows = s.details
        details.visibility = if (detailsOpen && rows.isNotEmpty()) View.VISIBLE else View.GONE
        if (details.visibility == View.VISIBLE) {
            detailsTitle.text = s.label("callDetails", "Call details")
            detailsGrid.removeAllViews()
            rows.forEach { r ->
                detailsGrid.addView(detailCell(r.getOrElse(0) { "" }, r.getOrElse(1) { "" }))
            }
        }
        val big = !detailsOpen || rows.isEmpty()
        sizeAvatar(avatar, if (big) 108 else 76, if (big) 36f else 26f)

        // Second line
        val second = s.second
        if (second != null) {
            secondBanner.visibility = View.VISIBLE
            val sName = second["name"] as? String ?: ""
            secondText.text = second["text"] as? String ?: (sName + " · " + s.label("onHold", "On hold"))
            secondSwap.text = second["label"] as? String ?: s.label("swap", "Swap")
            secondAction = second["action"] as? String ?: "swap"
        } else {
            secondBanner.visibility = View.GONE
        }

        // Controls
        setControl("mute", if (s.muted) R.drawable.ic_mic_off else R.drawable.ic_mic,
            if (s.muted) s.label("unmute", "Unmute") else s.label("mute", "Mute"), s.muted)
        setControl("keypad", R.drawable.ic_dialpad, s.label("keypad", "Keypad"), false)
        val routeIcon = if (s.route == "bluetooth") R.drawable.ic_bluetooth else R.drawable.ic_speaker
        val routeLabel = when (s.route) {
            "bluetooth" -> s.label("bluetooth", "Bluetooth")
            "wired" -> s.label("headset", "Headset")
            else -> s.label("speaker", "Speaker")
        }
        setControl("speaker", routeIcon, routeLabel, s.route == "speaker" || s.route == "bluetooth")
        setControl("hold", R.drawable.ic_pause,
            if (s.held) s.label("resume", "Resume") else s.label("hold", "Hold"), s.held)
        setControl("add", R.drawable.ic_add, s.label("addCall", "Add call"), false)
        setControl("transfer", R.drawable.ic_transfer, s.label("transfer", "Transfer"), false)
        setControl("record", R.drawable.ic_record,
            if (s.recording) s.label("stopRecord", "Stop rec") else s.label("record", "Record"),
            s.recording, danger = true)
        controls["record"]?.let { (img, t) ->
            val v = if (s.canRecord) View.VISIBLE else View.INVISIBLE
            img.visibility = v
            t.visibility = v
        }
        setControl("message", R.drawable.ic_message, s.label("message", "Message"), false)

        keypadHide.text = s.label("hide", "Hide")
        // Screen-off at the ear is driven from Dart (proximity_screen_lock), so it
        // also works while the Flutter app is in front during a call.
    }

    private fun updateTimer() {
        if (!::timer.isInitialized) return
        val start = snap.startedAt
        if (start <= 0) {
            timer.visibility = View.GONE
            return
        }
        timer.visibility = View.VISIBLE
        val sec = ((System.currentTimeMillis() - start) / 1000).coerceAtLeast(0)
        timer.text = if (sec >= 3600) String.format("%d:%02d:%02d", sec / 3600, sec / 60 % 60, sec % 60)
        else String.format("%02d:%02d", sec / 60, sec % 60)
    }

    private fun setProximity(on: Boolean) {
        if (on) {
            if (proximity?.isHeld == true) return
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!pm.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) return
            proximity = pm.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "medut:proximity").apply {
                acquire(4 * 60 * 60 * 1000L)
            }
        } else {
            proximity?.let { if (it.isHeld) it.release() }
            proximity = null
        }
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    private fun onControl(key: String) {
        val s = snap
        when (key) {
            "mute" -> NativeBridge.action(if (s.muted) "unmute" else "mute")
            "keypad" -> {
                keypadOpen = true
                dtmfTyped = ""
                keypadDigits.text = ""
                render(s)
            }
            "speaker" -> chooseRoute(s)
            "hold" -> NativeBridge.action(if (s.held) "unhold" else "hold")
            "add" -> openApp("add")
            "transfer" -> openApp("transfer")
            "record" -> NativeBridge.action("record")
            "message" -> openApp("message")
        }
    }

    /** One tap toggles the speaker; with a headset connected, pick the output. */
    private fun chooseRoute(s: CallSnapshot) {
        val routes = s.routes
        if (!s.bluetooth || routes.isEmpty()) {
            NativeBridge.action("toggleSpeaker")
            return
        }
        val names = routes.map { it["name"] as? String ?: "" }.toTypedArray()
        val current = routes.indexOfFirst { it["kind"] == s.route }.coerceAtLeast(0)
        AlertDialog.Builder(this)
            .setTitle(s.label("audioOutput", "Audio output"))
            .setSingleChoiceItems(names, current) { d, which ->
                NativeBridge.action("route", mapOf("routeId" to routes[which]["id"]))
                d.dismiss()
            }
            .show()
    }

    private fun openApp(route: String) {
        NativeBridge.action(route)
        MainActivity.open(this, route)
    }

    // ── View construction ────────────────────────────────────────────────────

    private fun dp(v: Int): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private fun pill(color: Int, radiusDp: Float, stroke: Int? = null): GradientDrawable =
        GradientDrawable().apply {
            setColor(color)
            cornerRadius = radiusDp * resources.displayMetrics.density
            if (stroke != null) setStroke(dp(1), stroke)
        }

    private fun oval(color: Int, stroke: Int? = null): GradientDrawable = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(color)
        if (stroke != null) setStroke(dp(1), stroke)
    }

    private fun text(sizeSp: Float, bold: Boolean = false, mono: Boolean = false): TextView =
        TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
            typeface = when {
                mono -> Typeface.MONOSPACE
                bold -> Typeface.create("sans-serif-medium", Typeface.BOLD)
                else -> Typeface.create("sans-serif", Typeface.NORMAL)
            }
            gravity = Gravity.CENTER
        }

    private fun lp(w: Int, h: Int, weight: Float = 0f) = LinearLayout.LayoutParams(w, h, weight)

    private fun spacer(weight: Float = 1f) = View(this).apply { layoutParams = lp(0, 0, weight).apply { height = 0; width = ViewGroup.LayoutParams.MATCH_PARENT } }

    private fun vspace(h: Int) = View(this).apply { layoutParams = lp(1, dp(h)) }

    private fun avatarView(sizeDp: Int, textSp: Float) = text(textSp, bold = true).apply {
        layoutParams = lp(dp(sizeDp), dp(sizeDp)).apply { gravity = Gravity.CENTER_HORIZONTAL }
    }

    private fun sizeAvatar(v: TextView, sizeDp: Int, textSp: Float) {
        val l = v.layoutParams
        if (l.width != dp(sizeDp)) {
            l.width = dp(sizeDp)
            l.height = dp(sizeDp)
            v.layoutParams = l
            v.setTextSize(TypedValue.COMPLEX_UNIT_SP, textSp)
        }
    }

    private fun roundButton(icon: Int, sizeDp: Int, label: String, onClick: () -> Unit): LinearLayout {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }
        val img = ImageView(this).apply {
            setImageResource(icon)
            scaleType = ImageView.ScaleType.CENTER
            layoutParams = lp(dp(sizeDp), dp(sizeDp))
            contentDescription = label
            setOnClickListener { onClick() }
        }
        val t = text(13f, bold = true).apply { this.text = label; setPadding(0, dp(8), 0, 0) }
        box.addView(img)
        box.addView(t)
        return box
    }

    private fun buildViews() {
        root = FrameLayout(this)
        root.fitsSystemWindows = true

        // ── Incoming ──
        incoming = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(16), dp(28), dp(16), dp(28))
        }
        inAccount = text(13f).apply {
            setPadding(dp(12), dp(6), dp(12), dp(6))
            layoutParams = lp(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        }
        inAvatar = avatarView(120, 42f)
        inName = text(30f, bold = true).apply { setPadding(0, dp(24), 0, dp(4)) }
        inNumber = text(16f)
        val quick = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        }
        inBusy = text(15f, bold = true).apply {
            layoutParams = lp(0, dp(52), 1f).apply { marginEnd = dp(8) }
            setOnClickListener {
                Ringer.stop()
                NativeBridge.action("busy")
            }
        }
        inMessage = text(15f, bold = true).apply {
            layoutParams = lp(0, dp(52), 1f)
            setOnClickListener { openApp("reply") }
        }
        quick.addView(inBusy)
        quick.addView(inMessage)
        val answerRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(12) }
        }
        inDecline = bigCallButton(R.drawable.ic_call_end) {
            Ringer.stop()
            CallNotifications.cancelIncoming(this)
            NativeBridge.action("decline")
        }.apply { layoutParams = lp(0, dp(72), 1f).apply { marginEnd = dp(8) } }
        inAnswer = bigCallButton(R.drawable.ic_call) {
            Ringer.stop()
            CallNotifications.cancelIncoming(this)
            NativeBridge.action("answer")
        }.apply { layoutParams = lp(0, dp(72), 1f) }
        answerRow.addView(inDecline)
        answerRow.addView(inAnswer)

        incoming.addView(inAccount)
        incoming.addView(spacer())
        incoming.addView(inAvatar)
        incoming.addView(inName)
        incoming.addView(inNumber)
        incoming.addView(spacer())
        incoming.addView(quick)
        incoming.addView(answerRow)

        // ── In call ──
        call = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(12), dp(16), dp(24))
        }
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        minimize = ImageView(this).apply {
            setImageResource(R.drawable.ic_chevron_down)
            scaleType = ImageView.ScaleType.CENTER
            layoutParams = lp(dp(44), dp(44))
            contentDescription = "Minimise"
            setOnClickListener { MainActivity.open(this@CallActivity) }
        }
        account = text(12f).apply { layoutParams = lp(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f) }
        qualityBars = QualityBars(this)
        qualityWord = text(12f, bold = true).apply { setPadding(dp(7), 0, dp(6), 0) }
        mosText = text(11f, mono = true)
        mosPill = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(10), dp(7), dp(10), dp(7))
            minimumHeight = dp(32)
            addView(qualityBars)
            addView(qualityWord)
            addView(mosText)
            setOnClickListener {
                detailsOpen = !detailsOpen
                render(snap)
            }
        }
        header.addView(minimize)
        header.addView(account)
        header.addView(mosPill)

        secondBanner = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(8), dp(8), dp(8))
            layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8) }
        }
        secondText = text(14f).apply {
            gravity = Gravity.START or Gravity.CENTER_VERTICAL
            layoutParams = lp(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        secondSwap = text(13f, bold = true).apply {
            setPadding(dp(14), dp(8), dp(14), dp(8))
            setOnClickListener { NativeBridge.action(secondAction) }
        }
        secondBanner.addView(secondText)
        secondBanner.addView(secondSwap)

        val callerBlock = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(0, dp(16), 0, dp(16))
        }
        avatar = avatarView(108, 36f)
        name = text(26f, bold = true).apply { setPadding(0, dp(10), 0, 0) }
        status = text(14f)
        timer = text(18f, mono = true).apply { setPadding(0, dp(4), 0, 0) }
        callerBlock.addView(avatar)
        callerBlock.addView(name)
        callerBlock.addView(status)
        callerBlock.addView(timer)

        details = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), dp(12), dp(14), dp(12))
            layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(12) }
        }
        detailsTitle = text(13f, bold = true).apply { gravity = Gravity.START }
        detailsGrid = GridLayout(this).apply {
            columnCount = 2
            setPadding(0, dp(8), 0, 0)
        }
        details.addView(detailsTitle)
        details.addView(detailsGrid)

        val grid = GridLayout(this).apply {
            columnCount = 4
            layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        }
        listOf("mute", "keypad", "speaker", "hold", "add", "transfer", "record", "message").forEach { key ->
            val cell = roundButton(R.drawable.ic_mic, 62, key) { onControl(key) }
            cell.layoutParams = GridLayout.LayoutParams(
                GridLayout.spec(GridLayout.UNDEFINED), GridLayout.spec(GridLayout.UNDEFINED, 1f),
            ).apply { width = 0; bottomMargin = dp(14) }
            controls[key] = (cell.getChildAt(0) as ImageView) to (cell.getChildAt(1) as TextView)
            grid.addView(cell)
        }

        hangup = ImageView(this).apply {
            setImageResource(R.drawable.ic_call_end)
            scaleType = ImageView.ScaleType.CENTER
            layoutParams = lp(dp(74), dp(74)).apply { gravity = Gravity.CENTER_HORIZONTAL; topMargin = dp(6) }
            contentDescription = "Hang up"
            setOnClickListener { NativeBridge.action("hangup") }
        }

        call.addView(header)
        call.addView(secondBanner)
        call.addView(spacer(0.5f))
        call.addView(callerBlock)
        call.addView(details)
        call.addView(spacer())
        call.addView(grid)
        call.addView(hangup)

        // ── Keypad ──
        keypad = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(32), dp(24), dp(32), dp(24))
        }
        keypadDigits = text(34f).apply {
            layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, dp(64))
        }
        val keys = GridLayout(this).apply { columnCount = 3 }
        listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#").forEach { d ->
            val k = text(28f).apply {
                this.text = d
                layoutParams = GridLayout.LayoutParams().apply {
                    width = dp(74); height = dp(74)
                    setMargins(dp(10), dp(7), dp(10), dp(7))
                }
                setOnClickListener {
                    dtmfTyped = (dtmfTyped + d).takeLast(24)
                    keypadDigits.text = dtmfTyped
                    NativeBridge.action("dtmf", mapOf("digit" to d))
                }
            }
            keypadKeys.add(k)
            keys.addView(k)
        }
        val keypadBottom = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(16) }
        }
        keypadHide = text(15f, bold = true).apply {
            layoutParams = lp(0, dp(56), 1f)
            setOnClickListener {
                keypadOpen = false
                render(snap)
            }
        }
        val keypadHangup = ImageView(this).apply {
            setImageResource(R.drawable.ic_call_end)
            scaleType = ImageView.ScaleType.CENTER
            layoutParams = lp(dp(74), dp(74))
            contentDescription = "Hang up"
            setOnClickListener { NativeBridge.action("hangup") }
        }
        keypadBottom.addView(keypadHide)
        keypadBottom.addView(keypadHangup)
        keypadBottom.addView(View(this).apply { layoutParams = lp(0, 1, 1f) })
        keypad.addView(spacer())
        keypad.addView(keypadDigits)
        keypad.addView(keys)
        keypad.addView(keypadBottom)

        val full = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        root.addView(incoming, full)
        root.addView(call, FrameLayout.LayoutParams(full))
        root.addView(keypad, FrameLayout.LayoutParams(full))
        applyPalette()
    }

    private fun bigCallButton(icon: Int, onClick: () -> Unit): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setOnClickListener { onClick() }
            addView(ImageView(this@CallActivity).apply { setImageResource(icon) })
            addView(text(17f, bold = true).apply { setPadding(dp(10), 0, 0, 0) })
        }

    private fun detailCell(k: String, v: String): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        setPadding(0, dp(5), 0, 0)
        layoutParams = GridLayout.LayoutParams(
            GridLayout.spec(GridLayout.UNDEFINED), GridLayout.spec(GridLayout.UNDEFINED, 1f),
        ).apply { width = 0; marginEnd = dp(12) }
        addView(text(11f, mono = true).apply {
            this.text = k
            setTextColor(p.text2)
            gravity = Gravity.START
            layoutParams = lp(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        })
        addView(text(11f, mono = true).apply {
            this.text = v
            setTextColor(p.text)
            gravity = Gravity.END
        })
    }

    private fun setControl(key: String, icon: Int, label: String, on: Boolean, danger: Boolean = false) {
        val (img, t) = controls[key] ?: return
        img.setImageResource(icon)
        img.contentDescription = label
        t.text = label
        t.setTextColor(p.text)
        if (on) {
            val bg = if (danger) p.danger else p.text
            img.background = oval(bg)
            img.imageTintList = ColorStateList.valueOf(if (danger) Color.WHITE else p.bg)
        } else {
            img.background = oval(p.surface, p.border)
            img.imageTintList = ColorStateList.valueOf(p.text)
        }
    }

    private fun applyPalette() {
        root.setBackgroundColor(p.bg)
        window.statusBarColor = p.bg
        window.navigationBarColor = p.bg
        if (Build.VERSION.SDK_INT >= 23) {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = if (paletteDark == true) 0 else View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
        }

        inAccount.setTextColor(p.text2)
        inAccount.background = pill(p.surface, 16f, p.border)
        inAvatar.setTextColor(p.accent)
        inAvatar.background = oval(p.accentSoft)
        inName.setTextColor(p.text)
        inNumber.setTextColor(p.text2)
        listOf(inBusy, inMessage).forEach {
            it.setTextColor(p.text)
            it.background = pill(p.surface, 18f, p.border)
        }
        inDecline.background = pill(p.danger, 24f)
        (inDecline.getChildAt(0) as ImageView).imageTintList = ColorStateList.valueOf(Color.WHITE)
        (inDecline.getChildAt(1) as TextView).setTextColor(Color.WHITE)
        inAnswer.background = pill(p.success, 24f)
        (inAnswer.getChildAt(0) as ImageView).imageTintList = ColorStateList.valueOf(p.onSuccess)
        (inAnswer.getChildAt(1) as TextView).setTextColor(p.onSuccess)

        minimize.imageTintList = ColorStateList.valueOf(p.text2)
        account.setTextColor(p.text2)
        secondBanner.background = pill(p.surface, 14f, p.border)
        secondText.setTextColor(p.text)
        secondSwap.setTextColor(p.accent)
        secondSwap.background = pill(p.accentSoft, 16f)
        avatar.setTextColor(p.accent)
        avatar.background = oval(p.accentSoft)
        name.setTextColor(p.text)
        status.setTextColor(p.text2)
        timer.setTextColor(p.text)
        details.background = pill(p.surface, 16f, p.border)
        detailsTitle.setTextColor(p.text)
        hangup.background = oval(p.danger)
        hangup.imageTintList = ColorStateList.valueOf(Color.WHITE)

        keypadDigits.setTextColor(p.text)
        keypadKeys.forEach {
            it.setTextColor(p.text)
            it.background = oval(p.surface, p.border)
        }
        keypadHide.setTextColor(p.accent)
        (keypad.getChildAt(3) as LinearLayout).getChildAt(1).apply {
            background = oval(p.danger)
            (this as ImageView).imageTintList = ColorStateList.valueOf(Color.WHITE)
        }
    }

    private fun initials(s: String): String {
        val parts = s.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (parts.isEmpty()) return "?"
        val first = parts[0]
        if (first.firstOrNull()?.isLetter() != true) return first.takeLast(2)
        return (parts[0].take(1) + (parts.getOrNull(1)?.take(1) ?: "")).uppercase()
    }

    companion object {
        const val EXTRA_ANSWER = "medut_answer"

        @Volatile
        var isShowing = false
            private set

        fun intent(context: Context): Intent =
            Intent(context, CallActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)

        fun open(context: Context) {
            context.startActivity(intent(context))
        }
    }
}
