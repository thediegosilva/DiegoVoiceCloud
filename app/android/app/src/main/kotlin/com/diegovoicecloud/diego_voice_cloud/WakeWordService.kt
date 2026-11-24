package com.diegovoicecloud.diego_voice_cloud

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import org.vosk.LibVosk
import org.vosk.LogLevel
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.RecognitionListener
import org.vosk.android.SpeechService
import kotlin.concurrent.thread

/**
 * Serviço em primeiro plano que fica escutando o nome da IA, offline e com a
 * tela apagada. Ao ouvir, acende a tela e abre o modo assistente.
 *
 * Também mantém o processo vivo para a rede entre aparelhos receber pedidos.
 */
class WakeWordService : Service(), RecognitionListener {

    companion object {
        const val ACTION_START = "start"
        const val ACTION_STOP = "stop"
        const val ACTION_PAUSE = "pause"
        const val ACTION_RESUME = "resume"
        const val ACTION_TEST_ON = "test_on"
        const val ACTION_TEST_OFF = "test_off"

        private const val CH_SERVICE = "assistant_listen"
        private const val NOTIF_ID = 41
        private const val TAG = "AssistantWake"

        @Volatile var running = false
    }

    private var model: Model? = null
    private var speech: SpeechService? = null
    private var phrases: List<String> = emptyList()
    private var listen = true
    private var highSensitivity = false
    private var paused = false
    /** Pausado porque uma conversa está usando o microfone. */
    private var pausedByApp = false
    private var testing = false
    private var lastWake = 0L
    private var loading = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START, null -> {
                intent?.getStringArrayListExtra("phrases")?.let { phrases = it }
                listen = intent?.getBooleanExtra("listen", true) ?: listen
                highSensitivity = intent?.getBooleanExtra("high", false) ?: highSensitivity
                if (!goForeground()) return START_NOT_STICKY
                running = true
                paused = false
                restart()
            }
            ACTION_STOP -> {
                stopListening()
                running = false
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_PAUSE -> { paused = true; pausedByApp = true; stopListening() }
            ACTION_RESUME -> { paused = false; pausedByApp = false; restart() }
            ACTION_TEST_ON -> { testing = true; restart() }
            ACTION_TEST_OFF -> { testing = false; restart() }
        }
        return START_STICKY
    }

    private fun goForeground(): Boolean {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CH_SERVICE, "Assistente em espera", NotificationManager.IMPORTANCE_MIN)
            )
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val name = phrases.firstOrNull()?.replaceFirstChar { it.uppercase() } ?: "Assistente"
        val notif = builder(CH_SERVICE)
            .setSmallIcon(R.drawable.ic_stat_assistant)
            .setContentTitle(if (listen) "Diga \"$name\" para me chamar" else "Rede entre aparelhos ativa")
            .setContentText(if (listen) "Escutando offline — nada sai do celular até você chamar." else "Recebendo pedidos dos seus outros aparelhos.")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        val micOk = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        if (listen && !micOk) listen = false
        return try {
            if (Build.VERSION.SDK_INT >= 34) {
                val type = if (listen) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                else ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                startForeground(NOTIF_ID, notif, type)
            } else if (Build.VERSION.SDK_INT >= 29 && listen) {
                startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIF_ID, notif)
            }
            true
        } catch (e: Exception) {
            // Android 14+: o microfone em segundo plano só pode começar com o
            // app aberto. Ex.: o sistema reiniciou o serviço sozinho.
            Log.w(TAG, "startForeground falhou: $e")
            running = false
            stopSelf()
            false
        }
    }

    private fun builder(channel: String) = WakeChannel.builder(this, channel)

    // ── Reconhecimento ───────────────────────────────────────

    private fun restart() {
        stopListening()
        if (!listen || paused) return
        if (!VoskModelStore.ready(this)) {
            WakeChannel.emit("status", mapOf("error" to "Modelo de voz ainda não foi baixado."))
            return
        }
        val m = model
        if (m == null) {
            if (loading) return
            loading = true
            thread(name = "vosk-load") {
                try {
                    LibVosk.setLogLevel(LogLevel.WARNINGS)
                    model = Model(VoskModelStore.dir(this).absolutePath)
                } catch (e: Exception) {
                    WakeChannel.emit("status", mapOf("error" to "Falha ao carregar o modelo: ${e.message}"))
                } finally {
                    loading = false
                }
                if (model != null) android.os.Handler(mainLooper).post { restart() }
            }
            return
        }
        try {
            val rec = if (testing) Recognizer(m, 16000f) else grammar(m)?.let { Recognizer(m, 16000f, it) } ?: Recognizer(m, 16000f)
            speech = SpeechService(rec, 16000f).also { it.startListening(this) }
            WakeChannel.emit("status", mapOf("listening" to true, "testing" to testing))
        } catch (e: Exception) {
            WakeChannel.emit("status", mapOf("error" to "Não consegui abrir o microfone: ${e.message}"))
        }
    }

    /**
     * Gramática = frases do nome + ~400 palavras comuns do português
     * ("concorrentes") + "[unk]".
     *
     * Só com o nome + "[unk]", o reconhecedor força quase tudo a virar o nome
     * ("diga" → "diego", "a lei diz" → "alexi"). Com as palavras comuns, ele
     * só escolhe o nome quando o nome foi mesmo falado. Medido com voz
     * sintética: Diego 24/24 acertos e 2/69 alarmes; Lexy (ouvido como
     * "léxico") 24/24 e 0/78 (fora dizer "léxico").
     *
     * Sensibilidade alta tira as palavras muito parecidas com o nome (acorda
     * mais fácil, mas também por engano).
     */
    private fun grammar(m: Model): String? {
        val valid = phrases.filter { p -> p.split(' ').all { VoskModelStore.knows(m, it) != false } }
        val missing = phrases - valid.toSet()
        WakeChannel.emit("status", mapOf("unknownWords" to missing, "knownPhrases" to valid))
        if (valid.isEmpty()) return null
        val keyWords = valid.flatMap { it.split(' ') }.map(::norm).toSet()
        val extra = distractors(m).filter { d ->
            val n = norm(d)
            n !in keyWords && (!highSensitivity || keyWords.none { levenshtein(it, n) <= 2 })
        }
        return JSONArray(valid + extra + "[unk]").toString()
    }

    private var distractorCache: List<String>? = null

    private fun distractors(m: Model): List<String> = distractorCache ?: try {
        resources.openRawResource(R.raw.wake_distractors).bufferedReader().use { it.readText() }
            .split(Regex("\\s+")).filter { it.isNotBlank() }.distinct()
            .filter { VoskModelStore.knows(m, it) != false }
    } catch (e: Exception) {
        Log.w(TAG, "distratores: $e"); emptyList()
    }.also { distractorCache = it }

    private fun levenshtein(a: String, b: String): Int {
        val d = IntArray(b.length + 1) { it }
        for (i in 1..a.length) {
            var prev = d[0]
            d[0] = i
            for (j in 1..b.length) {
                val tmp = d[j]
                d[j] = minOf(d[j] + 1, d[j - 1] + 1, prev + if (a[i - 1] == b[j - 1]) 0 else 1)
                prev = tmp
            }
        }
        return d[b.length]
    }

    private fun stopListening() {
        speech?.let {
            try { it.stop(); it.shutdown() } catch (_: Exception) {}
        }
        speech = null
    }

    private fun handleText(text: String, final: Boolean) {
        if (text.isBlank()) return
        if (testing) {
            if (final) WakeChannel.emit("heard", text)
            return
        }
        val padded = " ${norm(text)} "
        if (phrases.any { padded.contains(" ${norm(it)} ") }) wake()
    }

    /** Sem acentos, sem pontuação, minúsculas — para comparar falas. */
    private fun norm(s: String): String =
        java.text.Normalizer.normalize(s.lowercase(), java.text.Normalizer.Form.NFD)
            .replace(Regex("\\p{Mn}+"), "")
            .replace(Regex("[^a-z0-9]+"), " ")
            .trim()

    override fun onPartialResult(hypothesis: String?) =
        handleText(parse(hypothesis, "partial"), false)

    override fun onResult(hypothesis: String?) = handleText(parse(hypothesis, "text"), true)

    override fun onFinalResult(hypothesis: String?) = handleText(parse(hypothesis, "text"), true)

    override fun onError(exception: Exception?) {
        WakeChannel.emit("status", mapOf("error" to (exception?.message ?: "erro no microfone")))
    }

    override fun onTimeout() {}

    private fun parse(json: String?, key: String): String =
        try { JSONObject(json ?: "{}").optString(key).trim() } catch (_: Exception) { "" }

    // ── Acordar ──────────────────────────────────────────────

    private fun wake() {
        val now = System.currentTimeMillis()
        if (now - lastWake < 3000) return
        lastWake = now
        paused = true
        pausedByApp = false
        stopListening() // libera o microfone para a conversa

        WakeChannel.launchAssistant(this)

        // Se a conversa não abriu (ex.: notificação ignorada), volta a escutar.
        android.os.Handler(mainLooper).postDelayed({
            if (running && paused && !pausedByApp) { paused = false; restart() }
        }, 20000)
    }

    override fun onDestroy() {
        stopListening()
        model?.close()
        model = null
        running = false
        super.onDestroy()
    }
}
