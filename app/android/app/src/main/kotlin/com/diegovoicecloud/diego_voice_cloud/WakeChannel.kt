package com.diegovoicecloud.diego_voice_cloud

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Ponte Dart ↔ Android para a palavra de ativação. Canal "assistant/wake". */
object WakeChannel {
    private var channel: MethodChannel? = null
    private lateinit var app: Context
    private val main = Handler(Looper.getMainLooper())

    var activity: MainActivity? = null

    fun attach(context: Context, engine: FlutterEngine) {
        app = context.applicationContext
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "assistant/wake")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val phrases = call.argument<List<String>>("phrases") ?: emptyList()
                    val listen = call.argument<Boolean>("listen") ?: true
                    val i = Intent(app, WakeWordService::class.java)
                        .setAction(WakeWordService.ACTION_START)
                        .putStringArrayListExtra("phrases", ArrayList(phrases))
                        .putExtra("listen", listen)
                        .putExtra("high", call.argument<Boolean>("high") ?: false)
                    try {
                        if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(i) else app.startService(i)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("start", e.message, null)
                    }
                }
                "stop" -> { send(WakeWordService.ACTION_STOP); result.success(true) }
                "pause" -> { send(WakeWordService.ACTION_PAUSE); result.success(true) }
                "resume" -> { send(WakeWordService.ACTION_RESUME); result.success(true) }
                "test" -> {
                    send(if (call.argument<Boolean>("on") == true) WakeWordService.ACTION_TEST_ON else WakeWordService.ACTION_TEST_OFF)
                    result.success(true)
                }
                "isRunning" -> result.success(WakeWordService.running)
                "modelStatus" -> result.success(VoskModelStore.status(app))
                "downloadModel" -> {
                    VoskModelStore.download(app) { p, err ->
                        emit("modelProgress", mapOf("progress" to p, "error" to err))
                    }
                    result.success(true)
                }
                "canDrawOverlays" -> result.success(
                    Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(app)
                )
                "requestOverlay" -> {
                    if (Build.VERSION.SDK_INT >= 23) {
                        val i = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${app.packageName}"))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        app.startActivity(i)
                    }
                    result.success(true)
                }
                "isIgnoringBattery" -> {
                    val pm = app.getSystemService(Context.POWER_SERVICE) as PowerManager
                    result.success(Build.VERSION.SDK_INT < 23 || pm.isIgnoringBatteryOptimizations(app.packageName))
                }
                "requestBattery" -> {
                    if (Build.VERSION.SDK_INT >= 23) {
                        @Suppress("BatteryLife")
                        val i = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${app.packageName}"))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        app.startActivity(i)
                    }
                    result.success(true)
                }
                "finishWake" -> { activity?.finishWake(); result.success(true) }
                "openAssistant" -> { launchAssistant(app); result.success(true) }
                else -> result.notImplemented()
            }
        }
    }

    private fun send(action: String) {
        if (!WakeWordService.running) return
        app.startService(Intent(app, WakeWordService::class.java).setAction(action))
    }

    fun notifyWake() = emit("wake", null)

    private const val CH_WAKE = "assistant_wake"
    private const val WAKE_NOTIF_ID = 42

    @Suppress("DEPRECATION")
    fun builder(ctx: Context, channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, channel) else Notification.Builder(ctx)

    /**
     * Acende a tela e abre o modo assistente por cima de tudo (até da tela de
     * bloqueio). A tela, ao abrir, avisa o Dart com o evento "wake".
     */
    fun launchAssistant(ctx: Context) {
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        @Suppress("DEPRECATION")
        pm.newWakeLock(
            PowerManager.FULL_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
            "assistant:wake"
        ).acquire(5000)

        val i = Intent(ctx, MainActivity::class.java)
            .setAction(MainActivity.ACTION_WAKE)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)

        // Com "aparecer sobre outros apps", o Android deixa abrir a tela direto.
        val canOverlay = Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(ctx)
        if (canOverlay) {
            try { ctx.startActivity(i); return } catch (e: Exception) { Log.w("AssistantWake", "startActivity: $e") }
        }
        // Sem essa permissão: notificação de tela cheia (abre por cima do bloqueio).
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(CH_WAKE, "Assistente chamado", NotificationManager.IMPORTANCE_HIGH))
        }
        val pi = PendingIntent.getActivity(ctx, 1, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = builder(ctx, CH_WAKE)
            .setSmallIcon(R.drawable.ic_stat_assistant)
            .setContentTitle("Estou ouvindo")
            .setContentText("Toque para falar")
            .setCategory(Notification.CATEGORY_CALL)
            .setFullScreenIntent(pi, true)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .setTimeoutAfter(15000)
            .build()
        nm.notify(WAKE_NOTIF_ID, n)
    }

    /** Envia um evento ao Dart (sempre na thread principal). */
    fun emit(method: String, args: Any?) {
        main.post { channel?.invokeMethod(method, args) }
    }
}
