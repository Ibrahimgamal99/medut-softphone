package com.medut.generic.phone.call

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.LayerDrawable
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

// The ink surface: the same in both themes except the ground.
private const val INK = 0xFF0F1418.toInt()
private const val BLACK = 0xFF000000.toInt()
private const val TEXT = 0xFFF4F6F8.toInt()
private const val TEXT2 = 0xADFFFFFF.toInt() // 68 %
private const val FILL = 0x1FFFFFFF // 12 %: round buttons
private const val DOCK = 0x12FFFFFF // 7 %: the dock
private const val PILL = 0x1AFFFFFF // 10 %
private const val SHEET = 0xFF182027.toInt()
private const val LINE = 0x14FFFFFF // 8 %
private const val GOOD = 0xFF3DD49A.toInt()
private const val FAIR = 0xFFE9B04A.toInt()
private const val POOR = 0xFFFF5A5F.toInt()
private const val REC = 0xFFFF8A8D.toInt()
private const val END = 0xFFE5383B.toInt()
private const val ON_GOOD = 0xFF04271A.toInt()

/** (background, initials) per person: the app's dark avatar colours, picked the same way. */
private val AVATARS = listOf(
    0xFF163428.toInt() to 0xFF7DE3B8.toInt(),
    0xFF25214A.toInt() to 0xFFB7AEFF.toInt(),
    0xFF38261A.toInt() to 0xFFF4B27A.toInt(),
    0xFF162A3D.toInt() to 0xFF8EC0F2.toInt(),
)

/**
 * Native ringing + in-call screen (Pocket). Plain Views, built in code, so it
 * paints in one frame on a cold answer and over the lock screen. A dark "ink"
 * surface in both themes, the way most phones show a call: the caller, the
 * quality pill (tap it for every figure), four controls in a dock, then
 * Transfer · End · More. It holds no call state of its own: it renders
 * [CallState.latest] and sends every tap to Dart through [NativeBridge].
 */
class CallActivity : Activity() {

    private val ui = Handler(Looper.getMainLooper())
    private var snap = CallSnapshot(emptyMap())
    private var ground = 0
    /** The open sheet: "quality", "more" or null. */
    private var sheet: String? = null
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
    private lateinit var inDecline: TextView
    private lateinit var inAnswer: TextView

    // In call
    private lateinit var call: LinearLayout
    private lateinit var account: TextView
    private lateinit var secondPill: LinearLayout
    private lateinit var secondText: TextView
    private lateinit var secondSwap: TextView

    // A warm transfer under way: who is being consulted, Back to caller / Join & drop.
    private lateinit var xferBar: LinearLayout
    private lateinit var xferStatus: TextView
    private lateinit var xferHint: TextView
    private lateinit var xferBack: TextView
    private lateinit var xferJoin: TextView
    private lateinit var avatar: TextView
    private lateinit var name: TextView
    private lateinit var timer: TextView
    private lateinit var status: TextView
    private lateinit var qualityPill: LinearLayout
    private lateinit var qualityBars: QualityBars
    private lateinit var qualityWord: TextView
    private lateinit var mosText: TextView
    private lateinit var encrypted: TextView
    private lateinit var rec: TextView
    private val dock = mutableMapOf<String, Pair<ImageView, TextView>>()
    private lateinit var transfer: TextView
    private lateinit var more: TextView

    // Sheets
    private lateinit var dim: View
    private lateinit var qualitySheet: LinearLayout
    private lateinit var sheetTitle: TextView
    private lateinit var sheetPill: LinearLayout
    private lateinit var sheetBars: QualityBars
    private lateinit var sheetWord: TextView
    private lateinit var sheetMos: TextView
    private lateinit var mosYouLabel: TextView
    private lateinit var mosYou: TextView
    private lateinit var mosThemLabel: TextView
    private lateinit var mosThem: TextView
    private lateinit var sheetRows: LinearLayout
    private lateinit var moreSheet: LinearLayout
    private lateinit var moreAdd: TextView
    private lateinit var moreRecord: TextView
    private lateinit var moreMessage: TextView

    // Keypad
    private lateinit var keypad: LinearLayout
    private lateinit var keypadDigits: TextView
    private lateinit var keypadHide: TextView

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
        // Back closes a sheet or the keypad first, then leaves the call running
        // and shows the app, like the system dialer.
        when {
            sheet != null -> {
                sheet = null
                render(snap)
            }
            keypadOpen -> {
                keypadOpen = false
                render(snap)
            }
            else -> MainActivity.open(this)
        }
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
        val g = if (s.dark) BLACK else INK
        if (g != ground) {
            ground = g
            root.setBackgroundColor(g)
            window.statusBarColor = g
            window.navigationBarColor = g
        }
        root.layoutDirection = if (s.rtl) View.LAYOUT_DIRECTION_RTL else View.LAYOUT_DIRECTION_LTR

        val isIncoming = s.phase == "incoming"
        if (isIncoming) {
            sheet = null
            keypadOpen = false
        }
        incoming.visibility = vis(isIncoming)
        call.visibility = vis(!isIncoming && !keypadOpen)
        keypad.visibility = vis(!isIncoming && keypadOpen)

        val (avBg, avFg) = avatarColors(s.title)
        if (isIncoming) {
            inAccount.text = if (s.account.isNotBlank()) s.label("incomingOn", "Incoming on") + " " + s.account
            else s.label("incomingCall", "Incoming call")
            inAvatar.text = initials(s.title)
            inAvatar.background = rings(avBg)
            inAvatar.setTextColor(avFg)
            inName.text = s.title
            inNumber.text = if (s.name.isNotBlank()) s.number else ""
            inBusy.text = s.label("busy", "Busy")
            inMessage.text = s.label("message", "Message")
            inDecline.text = s.label("decline", "Decline")
            inAnswer.text = s.label("answer", "Answer")
            renderSheets(s)
            setProximity(false)
            return
        }

        account.text = s.account
        avatar.text = initials(s.title)
        avatar.background = rings(avBg)
        avatar.setTextColor(avFg)
        name.text = s.title
        updateTimer()
        // Calling / ringing / on hold, or a connection in trouble; otherwise the
        // number under a name until the call is answered.
        val line = when {
            s.phase == "outgoing" || s.phase == "held" || s.link != "ok" -> s.status
            s.startedAt <= 0 && s.name.isNotBlank() -> s.number
            else -> ""
        }
        status.text = line
        status.visibility = vis(line.isNotBlank())

        // Quality pill: 3 bars, the grade word and the MOS, in the grade's colour.
        if (s.qualityWord.isNotBlank()) {
            val fg = gradeColor(s.qualityLevel)
            qualityPill.visibility = View.VISIBLE
            qualityPill.background = pill(withAlpha(fg, 0x26), 18f)
            qualityBars.setQuality(s.qualityLevel, fg, 0x40FFFFFF)
            qualityWord.text = s.qualityWord
            qualityWord.setTextColor(fg)
            mosText.text = s.mos
            mosText.visibility = vis(s.mos.isNotBlank())
        } else {
            qualityPill.visibility = View.GONE
        }
        encrypted.text = s.label("encrypted", "Encrypted")
        encrypted.visibility = vis(s.encrypted)
        rec.text = "● " + s.label("recShort", "Rec")
        rec.visibility = vis(s.recording)

        val second = s.second
        if (second != null) {
            secondPill.visibility = View.VISIBLE
            val sName = second["name"] as? String ?: ""
            secondText.text = second["text"] as? String ?: (sName + " · " + s.label("onHold", "On hold"))
            secondSwap.text = second["label"] as? String ?: s.label("swap", "Swap")
            secondAction = second["action"] as? String ?: "swap"
        } else {
            secondPill.visibility = View.GONE
        }

        val xfer = s.transfer
        if (xfer != null) {
            // The bar replaces the "on hold · Complete" pill while it is up.
            secondPill.visibility = View.GONE
            xferBar.visibility = View.VISIBLE
            xferStatus.text = xfer["status"] as? String ?: ""
            xferHint.text = xfer["hint"] as? String ?: ""
            xferBack.text = xfer["back"] as? String ?: "Back to caller"
            xferJoin.text = xfer["join"] as? String ?: "Join & drop"
            val talking = xfer["phase"] == "talking"
            xferJoin.isEnabled = talking
            xferJoin.alpha = if (talking) 1f else 0.45f
        } else {
            xferBar.visibility = View.GONE
        }

        setDock("mute", if (s.muted) R.drawable.ic_mic_off else R.drawable.ic_mic, s.label("mute", "Mute"), s.muted)
        val routeIcon = if (s.route == "bluetooth") R.drawable.ic_bluetooth else R.drawable.ic_speaker
        val routeLabel = when (s.route) {
            "bluetooth" -> s.label("bluetooth", "Bluetooth")
            "wired" -> s.label("headset", "Headset")
            else -> s.label("speaker", "Speaker")
        }
        setDock("speaker", routeIcon, routeLabel, s.route == "speaker" || s.route == "bluetooth")
        setDock("keypad", R.drawable.ic_dialpad, s.label("keypad", "Keypad"), false)
        setDock("hold", R.drawable.ic_pause, if (s.held) s.label("resume", "Resume") else s.label("hold", "Hold"), s.held)
        transfer.text = s.label("transfer", "Transfer")
        more.text = s.label("more", "More")
        keypadHide.text = s.label("hide", "Hide")
        renderSheets(s)
        // Screen-off at the ear is driven from Dart (proximity_screen_lock), so it
        // also works while the Flutter app is in front during a call.
    }

    private fun renderSheets(s: CallSnapshot) {
        if (sheet == "quality" && (s.details.isEmpty() || s.phase == "incoming")) sheet = null
        dim.visibility = vis(sheet != null)
        qualitySheet.visibility = vis(sheet == "quality")
        moreSheet.visibility = vis(sheet == "more")
        if (sheet == "quality") {
            val fg = gradeColor(s.qualityLevel)
            sheetTitle.text = s.label("callQuality", "Call quality")
            sheetPill.background = pill(withAlpha(fg, 0x26), 18f)
            sheetBars.setQuality(s.qualityLevel, fg, 0x40FFFFFF)
            sheetWord.text = s.qualityWord
            sheetWord.setTextColor(fg)
            sheetMos.text = s.mos
            mosYouLabel.text = s.label("youHear", "You hear")
            mosYou.text = s.mosYou.ifBlank { "—" }
            mosThemLabel.text = s.label("theyHear", "They hear")
            mosThem.text = s.mosThem.ifBlank { "—" }
            sheetRows.removeAllViews()
            s.details.forEachIndexed { i, r ->
                if (i > 0) sheetRows.addView(View(this).apply {
                    setBackgroundColor(LINE)
                    layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, dp(1))
                })
                sheetRows.addView(detailRow(r.getOrElse(0) { "" }, r.getOrElse(1) { "" }))
            }
        }
        if (sheet == "more") {
            moreAdd.text = s.label("addCall", "Add call")
            moreRecord.text = if (s.recording) s.label("stopRecord", "Stop rec") else s.label("record", "Record")
            moreRecord.visibility = vis(s.canRecord)
            moreMessage.text = s.label("message", "Message")
        }
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

    private fun onDock(key: String) {
        val s = snap
        when (key) {
            "mute" -> NativeBridge.action(if (s.muted) "unmute" else "mute")
            "speaker" -> chooseRoute(s)
            "keypad" -> {
                keypadOpen = true
                dtmfTyped = ""
                keypadDigits.text = ""
                render(s)
            }
            "hold" -> NativeBridge.action(if (s.held) "unhold" else "hold")
        }
    }

    private fun openSheet(which: String?) {
        sheet = which
        render(snap)
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
        sheet = null
        NativeBridge.action(route)
        MainActivity.open(this, route)
    }

    // ── View construction ────────────────────────────────────────────────────

    private fun dp(v: Int): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private fun vis(on: Boolean) = if (on) View.VISIBLE else View.GONE

    private fun withAlpha(color: Int, alpha: Int) = color and 0x00FFFFFF or (alpha shl 24)

    private fun pill(color: Int, radiusDp: Float): GradientDrawable = GradientDrawable().apply {
        setColor(color)
        cornerRadius = radiusDp * resources.displayMetrics.density
    }

    private fun oval(color: Int): GradientDrawable = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(color)
    }

    /** The avatar disc inside two faint rings; the view is 44 dp wider than the disc. */
    private fun rings(fill: Int): Drawable = LayerDrawable(arrayOf(oval(0x08FFFFFF), oval(0x0DFFFFFF), oval(fill))).apply {
        setLayerInset(1, dp(10), dp(10), dp(10), dp(10))
        setLayerInset(2, dp(22), dp(22), dp(22), dp(22))
    }

    private fun gradeColor(level: Int) = when (level) {
        4, 3 -> GOOD
        2 -> FAIR
        1 -> POOR
        else -> TEXT2
    }

    private fun avatarColors(title: String): Pair<Int, Int> {
        var h = 0L
        for (c in title) h = (h * 31 + c.code) and 0x7fffffffL
        return AVATARS[(h % AVATARS.size).toInt()]
    }

    private fun text(sizeSp: Float, weight: Int = 400, color: Int = TEXT, mono: Boolean = false): TextView =
        TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
            typeface = when {
                mono -> Typeface.MONOSPACE
                Build.VERSION.SDK_INT >= 28 -> Typeface.create(Typeface.DEFAULT, weight, false)
                weight >= 600 -> Typeface.create("sans-serif-medium", Typeface.BOLD)
                else -> Typeface.create("sans-serif", Typeface.NORMAL)
            }
            setTextColor(color)
            gravity = Gravity.CENTER
        }

    private fun lp(w: Int, h: Int, weight: Float = 0f) = LinearLayout.LayoutParams(w, h, weight)

    private fun wrap() = lp(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)

    private fun spacer(weight: Float = 1f) = View(this).apply { layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, 0, weight) }

    private fun icon(res: Int, sizeDp: Int, bg: Drawable?, tint: Int, description: String, onClick: () -> Unit) =
        ImageView(this).apply {
            setImageResource(res)
            scaleType = ImageView.ScaleType.CENTER
            layoutParams = lp(dp(sizeDp), dp(sizeDp))
            background = bg
            imageTintList = ColorStateList.valueOf(tint)
            contentDescription = description
            setOnClickListener { onClick() }
        }

    /** A round button with its label under it, filling an equal share of a row. */
    private fun cell(img: ImageView, labelSp: Float, labelWeight: Int = 500): Pair<LinearLayout, TextView> {
        val label = text(labelSp, labelWeight, TEXT2).apply { setPadding(0, dp(6), 0, 0) }
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            layoutParams = lp(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            addView(img)
            addView(label)
        }
        return box to label
    }

    private fun handle() = View(this).apply {
        background = pill(0x33FFFFFF, 3f)
        layoutParams = lp(dp(38), dp(5)).apply { gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = dp(14) }
    }

    private fun sheetPanel(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(20), dp(10), dp(20), dp(24))
        isClickable = true // taps on the sheet don't reach the dim behind it
        background = GradientDrawable().apply {
            setColor(SHEET)
            val r = 26f * resources.displayMetrics.density
            cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
        }
        addView(handle())
    }

    private fun qualityPillView(): Triple<LinearLayout, QualityBars, Pair<TextView, TextView>> {
        val bars = QualityBars(this)
        val word = text(13f, 700).apply { setPadding(dp(7), 0, dp(6), 0) }
        val mos = text(11.5f, color = TEXT2, mono = true)
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(11), dp(6), dp(10), dp(6))
            addView(bars)
            addView(word)
            addView(mos)
        }
        return Triple(box, bars, word to mos)
    }

    private fun buildViews() {
        root = FrameLayout(this)
        root.fitsSystemWindows = true
        buildIncoming()
        buildCall()
        buildKeypad()
        buildSheets()
        root.setBackgroundColor(INK)
        if (Build.VERSION.SDK_INT >= 23) {
            // Light status-bar icons on the ink, in both themes.
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = 0
        }
    }

    private fun buildIncoming() {
        incoming = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(16), dp(24), dp(16), dp(28))
        }
        inAccount = text(13f, color = TEXT2).apply {
            setPadding(dp(14), dp(6), dp(14), dp(6))
            background = pill(PILL, 16f)
            layoutParams = wrap()
        }
        inAvatar = text(40f, 700).apply { layoutParams = lp(dp(164), dp(164)) }
        inName = text(30f, 800).apply { setPadding(0, dp(18), 0, dp(4)) }
        inNumber = text(16f, color = TEXT2)

        val quick = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        }
        inBusy = text(15f, 600).apply {
            background = pill(PILL, 24f)
            layoutParams = lp(0, dp(48), 1f).apply { marginEnd = dp(8) }
            setOnClickListener {
                Ringer.stop()
                NativeBridge.action("busy")
            }
        }
        inMessage = text(15f, 600).apply {
            background = pill(PILL, 24f)
            layoutParams = lp(0, dp(48), 1f)
            setOnClickListener { openApp("reply") }
        }
        quick.addView(inBusy)
        quick.addView(inMessage)

        val answerRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(28) }
        }
        val decline = cell(icon(R.drawable.ic_call_end, 72, oval(END), Color.WHITE, "Decline") {
            Ringer.stop()
            CallNotifications.cancelIncoming(this)
            NativeBridge.action("decline")
        }, 13f, 600)
        val answer = cell(icon(R.drawable.ic_call, 72, oval(GOOD), ON_GOOD, "Answer") {
            Ringer.stop()
            CallNotifications.cancelIncoming(this)
            NativeBridge.action("answer")
        }, 13f, 600)
        inDecline = decline.second
        inAnswer = answer.second
        answerRow.addView(decline.first)
        answerRow.addView(answer.first)

        incoming.addView(inAccount)
        incoming.addView(spacer())
        incoming.addView(inAvatar)
        incoming.addView(inName)
        incoming.addView(inNumber)
        incoming.addView(spacer())
        incoming.addView(quick)
        incoming.addView(answerRow)
        root.addView(incoming, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    private fun buildCall() {
        call = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), dp(6), dp(14), dp(18))
        }

        // Minimise · account
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        header.addView(icon(R.drawable.ic_chevron_down, 44, null, TEXT2, "Minimise") { MainActivity.open(this) })
        account = text(12.5f, color = TEXT2).apply { layoutParams = lp(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f) }
        header.addView(account)
        header.addView(View(this).apply { layoutParams = lp(dp(44), 1) })

        // The other call: on hold, waiting, or the transfer to complete.
        secondText = text(13f, 600)
        secondSwap = text(12.5f, 700).apply {
            setPadding(dp(12), dp(5), dp(12), dp(5))
            background = pill(0x29FFFFFF, 16f)
            layoutParams = wrap().apply { marginStart = dp(8) }
            setOnClickListener { NativeBridge.action(secondAction) }
        }
        secondPill = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(5), dp(5), dp(5))
            background = pill(PILL, 20f)
            layoutParams = wrap().apply { gravity = Gravity.CENTER_HORIZONTAL; topMargin = dp(4) }
            addView(secondText)
            addView(secondSwap)
        }

        xferStatus = text(14.5f, 700)
        xferHint = text(12f, color = TEXT2).apply { setPadding(dp(4), dp(3), dp(4), dp(12)) }
        xferBack = text(14f, 700).apply {
            setPadding(dp(14), dp(12), dp(14), dp(12))
            background = pill(FILL, 24f)
            layoutParams = lp(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { marginEnd = dp(8) }
            setOnClickListener { NativeBridge.action("cancelTransfer") }
        }
        xferJoin = text(14f, 700, ON_GOOD).apply {
            setPadding(dp(14), dp(12), dp(14), dp(12))
            background = pill(GOOD, 24f)
            layoutParams = lp(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            setOnClickListener { NativeBridge.action("completeTransfer") }
        }
        xferBar = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(14), dp(12), dp(14), dp(14))
            background = pill(PILL, 22f)
            layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                .apply { setMargins(dp(20), dp(12), dp(20), 0) }
            addView(xferStatus)
            addView(xferHint)
            addView(LinearLayout(this@CallActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                addView(xferBack)
                addView(xferJoin)
            })
            visibility = View.GONE
        }

        // Caller, time, quality, tags
        avatar = text(36f, 700).apply { layoutParams = lp(dp(148), dp(148)).apply { gravity = Gravity.CENTER_HORIZONTAL } }
        name = text(30f, 800).apply { setPadding(dp(8), dp(14), dp(8), 0) }
        timer = text(17f, color = TEXT2).apply { fontFeatureSettings = "tnum" }
        status = text(14f, color = TEXT2).apply { setPadding(dp(8), dp(2), dp(8), 0) }
        val q = qualityPillView()
        qualityPill = q.first.apply {
            layoutParams = wrap().apply { gravity = Gravity.CENTER_HORIZONTAL; topMargin = dp(14) }
            contentDescription = "Call quality"
            setOnClickListener { openSheet("quality") }
        }
        qualityBars = q.second
        qualityWord = q.third.first
        mosText = q.third.second
        qualityPill.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_chevron_down)
            imageTintList = ColorStateList.valueOf(TEXT2)
            rotation = -90f
            layoutParams = lp(dp(16), dp(16)).apply { marginStart = dp(2) }
        })
        encrypted = text(12.5f, color = TEXT2).apply {
            val lock = getDrawable(R.drawable.ic_lock)?.mutate()?.apply { setBounds(0, 0, dp(14), dp(14)) }
            setCompoundDrawablesRelative(lock, null, null, null)
            compoundDrawableTintList = ColorStateList.valueOf(TEXT2)
            compoundDrawablePadding = dp(5)
            layoutParams = wrap().apply { marginEnd = dp(14) }
        }
        rec = text(12.5f, 600, REC).apply { layoutParams = wrap() }
        val tags = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(10) }
            addView(encrypted)
            addView(rec)
        }

        // The dock: Mute, Speaker, Keypad, Hold.
        val dockRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(6), dp(14), dp(6), dp(12))
            background = pill(DOCK, 28f)
        }
        listOf("mute", "speaker", "keypad", "hold").forEach { key ->
            val img = icon(R.drawable.ic_mic, 54, oval(FILL), TEXT, key) { onDock(key) }
            val (box, label) = cell(img, 11.5f)
            dock[key] = img to label
            dockRow.addView(box)
        }

        // Transfer · End · More
        val bottom = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(18) }
        }
        val t = cell(icon(R.drawable.ic_transfer, 46, oval(FILL), TEXT, "Transfer") { openApp("transfer") }, 11.5f)
        transfer = t.second
        val hang = icon(R.drawable.ic_call_end, 0, pill(END, 29f), Color.WHITE, "Hang up") { NativeBridge.action("hangup") }.apply {
            layoutParams = lp(dp(88), dp(60))
        }
        val m = cell(icon(R.drawable.ic_more, 46, oval(FILL), TEXT, "More") { openSheet("more") }, 11.5f)
        more = m.second
        bottom.addView(t.first)
        bottom.addView(hang)
        bottom.addView(m.first)

        call.addView(header)
        call.addView(secondPill)
        call.addView(spacer())
        call.addView(avatar)
        call.addView(name)
        call.addView(timer)
        call.addView(status)
        call.addView(qualityPill)
        call.addView(tags)
        call.addView(xferBar)
        call.addView(spacer())
        call.addView(dockRow)
        call.addView(bottom)
        root.addView(call, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    private fun buildKeypad() {
        keypad = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(32), dp(24), dp(32), dp(24))
        }
        keypadDigits = text(34f).apply { layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, dp(64)) }
        val keys = GridLayout(this).apply { columnCount = 3 }
        listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#").forEach { d ->
            keys.addView(text(28f, 500).apply {
                this.text = d
                background = oval(FILL)
                layoutParams = GridLayout.LayoutParams().apply {
                    width = dp(74); height = dp(74)
                    setMargins(dp(10), dp(7), dp(10), dp(7))
                }
                setOnClickListener {
                    dtmfTyped = (dtmfTyped + d).takeLast(24)
                    keypadDigits.text = dtmfTyped
                    NativeBridge.action("dtmf", mapOf("digit" to d))
                }
            })
        }
        val bottom = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(16) }
        }
        keypadHide = text(15f, 600, TEXT2).apply {
            layoutParams = lp(0, dp(56), 1f)
            setOnClickListener {
                keypadOpen = false
                render(snap)
            }
        }
        bottom.addView(keypadHide)
        bottom.addView(icon(R.drawable.ic_call_end, 74, oval(END), Color.WHITE, "Hang up") { NativeBridge.action("hangup") })
        bottom.addView(View(this).apply { layoutParams = lp(0, 1, 1f) })
        keypad.addView(spacer())
        keypad.addView(keypadDigits)
        keypad.addView(keys)
        keypad.addView(bottom)
        root.addView(keypad, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    private fun buildSheets() {
        dim = View(this).apply {
            setBackgroundColor(0x80000000.toInt())
            setOnClickListener { openSheet(null) }
        }
        root.addView(dim, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        val bottom = { FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM) }

        // Call quality: the pill again, each direction's MOS, then every figure.
        qualitySheet = sheetPanel()
        val head = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(12) }
        }
        sheetTitle = text(19f, 800).apply {
            gravity = Gravity.START or Gravity.CENTER_VERTICAL
            layoutParams = lp(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val sp = qualityPillView()
        sheetPill = sp.first
        sheetBars = sp.second
        sheetWord = sp.third.first
        sheetMos = sp.third.second
        head.addView(sheetTitle)
        head.addView(sheetPill)

        val mosRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = lp(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(6) }
        }
        fun mosBox(endMargin: Int): Pair<TextView, TextView> {
            val label = text(11.5f, color = TEXT2).apply { gravity = Gravity.START }
            val value = text(24f, 800).apply { gravity = Gravity.START; fontFeatureSettings = "tnum" }
            mosRow.addView(LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(12), dp(9), dp(12), dp(9))
                background = pill(0x0FFFFFFF, 16f)
                layoutParams = lp(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { marginEnd = endMargin }
                addView(label)
                addView(value)
            })
            return label to value
        }
        mosBox(dp(8)).let { mosYouLabel = it.first; mosYou = it.second }
        mosBox(0).let { mosThemLabel = it.first; mosThem = it.second }
        sheetRows = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        qualitySheet.addView(head)
        qualitySheet.addView(mosRow)
        qualitySheet.addView(sheetRows)
        root.addView(qualitySheet, bottom())

        // More: what doesn't fit in the dock.
        moreSheet = sheetPanel()
        fun row(res: Int, onClick: () -> Unit) = text(16f, 600).apply {
            gravity = Gravity.START or Gravity.CENTER_VERTICAL
            setPadding(0, dp(14), 0, dp(14))
            setCompoundDrawablesRelativeWithIntrinsicBounds(res, 0, 0, 0)
            compoundDrawableTintList = ColorStateList.valueOf(TEXT)
            compoundDrawablePadding = dp(16)
            setOnClickListener { onClick() }
            moreSheet.addView(this)
        }
        moreAdd = row(R.drawable.ic_add) { openApp("add") }
        moreRecord = row(R.drawable.ic_record) {
            NativeBridge.action("record")
            openSheet(null)
        }
        moreMessage = row(R.drawable.ic_message) { openApp("message") }
        root.addView(moreSheet, bottom())
    }

    private fun detailRow(k: String, v: String): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(0, dp(8), 0, dp(8))
        addView(text(13f, color = TEXT2).apply {
            this.text = k
            gravity = Gravity.START
            layoutParams = lp(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        })
        addView(text(12f, mono = true).apply {
            this.text = v
            gravity = Gravity.END
        })
    }

    private fun setDock(key: String, res: Int, label: String, on: Boolean) {
        val (img, t) = dock[key] ?: return
        img.setImageResource(res)
        img.contentDescription = label
        img.background = oval(if (on) TEXT else FILL)
        img.imageTintList = ColorStateList.valueOf(if (on) INK else TEXT)
        t.text = label
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
