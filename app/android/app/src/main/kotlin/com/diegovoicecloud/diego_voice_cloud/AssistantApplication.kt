package com.diegovoicecloud.diego_voice_cloud

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Cria o motor do Flutter junto com o processo (e não junto com a tela).
 *
 * Assim o Dart continua rodando — rede entre aparelhos, retomar a escuta —
 * mesmo depois que o usuário fecha a tela do app, enquanto o serviço de
 * escuta mantém o processo vivo.
 */
class AssistantApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        WakeChannel.attach(this, engine)
        CallAudio.attach(this, engine)
    }

    companion object {
        const val ENGINE_ID = "main"
    }
}
