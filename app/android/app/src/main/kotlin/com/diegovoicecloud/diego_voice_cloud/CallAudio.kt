package com.diegovoicecloud.diego_voice_cloud

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.LinkedBlockingQueue
import kotlin.concurrent.thread

/**
 * Áudio da conversa no Android, como numa chamada de voz.
 *
 * - Escolhe a saída/entrada: fone Bluetooth > fone com fio/USB > alto-falante,
 *   e troca sozinho se um fone conectar ou desconectar no meio da conversa.
 *   Com fone Bluetooth, o microfone do fone também é usado (dá para falar
 *   longe do celular).
 * - Toca a voz da IA com um AudioTrack de "chamada" (USAGE_VOICE_COMMUNICATION):
 *   é esse tipo de som que o Android manda para o fone Bluetooth e que o
 *   cancelamento de eco usa como referência.
 *
 * Canal "assistant/audio".
 */
object CallAudio {
    private const val TAG = "CallAudio"
    private const val RATE = 24000

    private lateinit var app: Context
    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())
    private val am get() = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var active = false
    private var prevMode = AudioManager.MODE_NORMAL
    @Suppress("DEPRECATION") private var prevSpeaker = false
    private var focus: AudioFocusRequest? = null // API 26+
    private var scoReceiver: BroadcastReceiver? = null
    private var currentRoute = ""

    // Player
    private var track: AudioTrack? = null
    private val queue = LinkedBlockingQueue<ByteArray>()
    @Volatile private var playing = false
    @Volatile private var generation = 0

    fun attach(context: Context, engine: FlutterEngine) {
        app = context.applicationContext
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "assistant/audio")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> { start(); result.success(currentRoute) }
                    "stop" -> { stop(); result.success(null) }
                    "play" -> { enqueue(call.arguments as ByteArray); result.success(null) }
                    "flush" -> { flush(); result.success(null) }
                    "route" -> result.success(currentRoute)
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.e(TAG, "${call.method}: $e")
                result.error(call.method, e.message, null)
            }
        }
    }

    // ── Rota (fone Bluetooth / com fio / alto-falante) ─────────────

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = reroute()
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = reroute()
    }

    @Suppress("DEPRECATION")
    private fun start() {
        if (!active) {
            prevMode = am.mode
            prevSpeaker = am.isSpeakerphoneOn
            active = true
            requestFocus()
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            am.registerAudioDeviceCallback(deviceCallback, main)
        }
        route()
        startPlayer()
    }

    @Suppress("DEPRECATION")
    private fun stop() {
        stopPlayer()
        if (!active) return
        active = false
        try { am.unregisterAudioDeviceCallback(deviceCallback) } catch (_: Exception) {}
        if (Build.VERSION.SDK_INT >= 31) {
            am.clearCommunicationDevice()
        } else {
            stopSco()
        }
        am.isSpeakerphoneOn = prevSpeaker
        am.mode = prevMode
        abandonFocus()
        currentRoute = ""
    }

    private fun reroute() {
        if (!active) return
        // Espera o sistema terminar de registrar o aparelho.
        main.postDelayed({ if (active) route() }, 400)
    }

    private fun isBt(t: Int) = t == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
        (Build.VERSION.SDK_INT >= 31 && (t == AudioDeviceInfo.TYPE_BLE_HEADSET || t == AudioDeviceInfo.TYPE_BLE_SPEAKER))

    private fun isWired(t: Int) = t == AudioDeviceInfo.TYPE_WIRED_HEADSET || t == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
        t == AudioDeviceInfo.TYPE_USB_HEADSET

    @Suppress("DEPRECATION")
    private fun route() {
        val newRoute: String
        if (Build.VERSION.SDK_INT >= 31) {
            val devs = am.availableCommunicationDevices
            val pick = devs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLE_HEADSET }
                ?: devs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
                ?: devs.firstOrNull { isWired(it.type) }
                ?: devs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            if (pick != null && am.communicationDevice?.id != pick.id) {
                val ok = am.setCommunicationDevice(pick)
                Log.i(TAG, "rota → ${pick.productName} (${pick.type}) ok=$ok")
            }
            newRoute = when {
                pick == null -> "speaker"
                isBt(pick.type) -> "bluetooth:${pick.productName}"
                isWired(pick.type) -> "wired"
                else -> "speaker"
            }
        } else {
            val outs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            val bt = outs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
            val wired = outs.firstOrNull { isWired(it.type) }
            when {
                bt != null && am.isBluetoothScoAvailableOffCall -> {
                    am.isSpeakerphoneOn = false
                    startSco()
                    newRoute = "bluetooth:${bt.productName}"
                }
                wired != null -> { stopSco(); am.isSpeakerphoneOn = false; newRoute = "wired" }
                else -> { stopSco(); am.isSpeakerphoneOn = true; newRoute = "speaker" }
            }
        }
        if (newRoute != currentRoute) {
            currentRoute = newRoute
            main.post { channel?.invokeMethod("route", newRoute) }
        }
    }

    @Suppress("DEPRECATION")
    private fun startSco() {
        if (scoReceiver == null) {
            val r = object : BroadcastReceiver() {
                override fun onReceive(c: Context, i: Intent) {
                    val st = i.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, -1)
                    if (st == AudioManager.SCO_AUDIO_STATE_CONNECTED) am.isBluetoothScoOn = true
                }
            }
            app.registerReceiver(r, IntentFilter(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED))
            scoReceiver = r
        }
        am.startBluetoothSco()
        am.isBluetoothScoOn = true
    }

    @Suppress("DEPRECATION")
    private fun stopSco() {
        scoReceiver?.let { try { app.unregisterReceiver(it) } catch (_: Exception) {} }
        scoReceiver = null
        if (am.isBluetoothScoOn) {
            am.isBluetoothScoOn = false
            am.stopBluetoothSco()
        }
    }

    @Suppress("DEPRECATION")
    private fun requestFocus() {
        if (Build.VERSION.SDK_INT < 26) {
            am.requestAudioFocus(null, AudioManager.STREAM_VOICE_CALL, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            return
        }
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(attrs)
            .setOnAudioFocusChangeListener { }
            .build()
        am.requestAudioFocus(req)
        focus = req
    }

    @Suppress("DEPRECATION")
    private fun abandonFocus() {
        if (Build.VERSION.SDK_INT < 26) am.abandonAudioFocus(null)
        else focus?.let { am.abandonAudioFocusRequest(it) }
        focus = null
    }

    // ── Player (voz da IA) ─────────────────────────────────────────

    private fun startPlayer() {
        if (track != null) return
        val minBuf = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(RATE)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setBufferSizeInBytes(maxOf(minBuf * 2, RATE / 5 * 2)) // ~200 ms
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        t.play()
        track = t
        playing = true
        val gen = ++generation
        thread(name = "ia-voz") {
            while (playing && gen == generation) {
                val chunk = try { queue.take() } catch (_: InterruptedException) { break }
                if (chunk.isEmpty() || gen != generation) continue
                try { t.write(chunk, 0, chunk.size) } catch (_: Exception) { break }
            }
        }
    }

    private fun enqueue(bytes: ByteArray) {
        if (track == null) startPlayer()
        queue.offer(bytes)
    }

    /** Usuário interrompeu: descarta o que ainda não tocou. */
    private fun flush() {
        queue.clear()
        track?.let {
            try { it.pause(); it.flush(); it.play() } catch (_: Exception) {}
        }
    }

    private fun stopPlayer() {
        playing = false
        generation++
        queue.clear()
        queue.offer(ByteArray(0)) // acorda a thread
        track?.let { try { it.pause(); it.flush(); it.release() } catch (_: Exception) {} }
        track = null
    }
}
