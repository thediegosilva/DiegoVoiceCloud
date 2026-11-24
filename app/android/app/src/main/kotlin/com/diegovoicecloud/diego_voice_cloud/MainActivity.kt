package com.diegovoicecloud.diego_voice_cloud

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {

    // Usa o motor criado no AssistantApplication (sobrevive ao fechar a tela).
    override fun getCachedEngineId(): String = AssistantApplication.ENGINE_ID

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WakeChannel.activity = this
        handleWake(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleWake(intent)
    }

    override fun onDestroy() {
        if (WakeChannel.activity === this) WakeChannel.activity = null
        super.onDestroy()
    }

    private fun handleWake(intent: Intent?) {
        if (intent?.action != ACTION_WAKE) return
        intent.action = Intent.ACTION_MAIN // não dispara de novo ao recriar a tela
        setOverLockScreen(true)
        WakeChannel.notifyWake()
    }

    /** Aparece por cima da tela de bloqueio e acende a tela (estilo Siri). */
    fun setOverLockScreen(on: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(flags) else window.clearFlags(flags)
        }
        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    /** Fim da conversa do modo assistente: some e devolve a tela anterior. */
    fun finishWake() {
        setOverLockScreen(false)
        // Se o celular estava bloqueado, volta para a tela de bloqueio e a
        // tela apaga sozinha no tempo normal do sistema.
        moveTaskToBack(true)
    }

    companion object {
        const val ACTION_WAKE = "com.diegovoicecloud.assistant.WAKE"
    }
}
