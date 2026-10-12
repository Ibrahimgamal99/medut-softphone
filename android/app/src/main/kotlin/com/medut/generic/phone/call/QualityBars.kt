package com.medut.generic.phone.call

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.view.View

/**
 * Three rising signal bars for call quality, as in Echo. [setQuality] takes
 * the 0–4 grade (4 shows as 3 bars) and the colour of the lit bars.
 */
class QualityBars(context: Context) : View(context) {
    private val density = resources.displayMetrics.density
    private val barWidth = 4f * density
    private val gap = barWidth * 0.7f
    private val corner = barWidth / 2f
    private val maxBarHeight = barWidth * 1.75f + 2 * barWidth * 1.25f
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rect = RectF()
    private var level = 0
    private var litColor = 0
    private var offColor = 0x26FFFFFF

    fun setQuality(level: Int, litColor: Int, offColor: Int) {
        val clamped = level.coerceIn(0, 3)
        if (clamped == this.level && litColor == this.litColor && offColor == this.offColor) return
        this.level = clamped
        this.litColor = litColor
        this.offColor = offColor
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = (barWidth * 3 + gap * 2).toInt() + paddingLeft + paddingRight
        val h = maxBarHeight.toInt() + paddingTop + paddingBottom
        setMeasuredDimension(resolveSize(w, widthMeasureSpec), resolveSize(h, heightMeasureSpec))
    }

    override fun onDraw(canvas: Canvas) {
        val bottom = (height - paddingBottom).toFloat()
        var x = paddingLeft.toFloat()
        for (i in 0 until 3) {
            val h = barWidth * 1.75f + i * barWidth * 1.25f
            paint.color = if (i < level) litColor else offColor
            rect.set(x, bottom - h, x + barWidth, bottom)
            canvas.drawRoundRect(rect, corner, corner, paint)
            x += barWidth + gap
        }
    }
}
