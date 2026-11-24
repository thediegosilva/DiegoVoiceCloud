package com.diegovoicecloud.diego_voice_cloud

import android.content.Context
import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.Pointer
import org.vosk.Model
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipInputStream
import kotlin.concurrent.thread

/**
 * Modelo de reconhecimento de voz offline (Vosk, português, ~32 MB).
 * É baixado uma vez para dentro do app — o áudio nunca sai do celular
 * enquanto ele só está esperando o nome.
 */
object VoskModelStore {
    private const val URL_PT = "https://alphacephei.com/vosk/models/vosk-model-small-pt-0.3.zip"

    @Volatile var downloading = false
    @Volatile var progress = 0.0

    fun dir(ctx: Context) = File(ctx.filesDir, "vosk-pt")

    fun ready(ctx: Context) =
        File(dir(ctx), "final.mdl").isFile || File(dir(ctx), "am/final.mdl").isFile

    fun status(ctx: Context): Map<String, Any> =
        mapOf("ready" to ready(ctx), "downloading" to downloading, "progress" to progress)

    /** Função nativa do Vosk que a biblioteca Java não expõe. */
    private interface VoskExtra : Library {
        fun vosk_model_find_word(model: Pointer, word: String): Int
    }

    private val extra: VoskExtra? by lazy {
        try { Native.load("vosk", VoskExtra::class.java) } catch (_: Throwable) { null }
    }

    /** O modelo conhece esta palavra? (null = não deu para verificar) */
    fun knows(model: Model, word: String): Boolean? =
        try { extra?.vosk_model_find_word(model.pointer, word)?.let { it >= 0 } } catch (_: Throwable) { null }

    fun download(ctx: Context, onProgress: (Double, String?) -> Unit) {
        if (downloading) return
        if (ready(ctx)) { onProgress(1.0, null); return }
        downloading = true
        progress = 0.0
        thread(name = "vosk-download") {
            val zip = File(ctx.cacheDir, "vosk-pt.zip")
            val tmp = File(ctx.filesDir, "vosk-pt-tmp")
            try {
                val conn = URL(URL_PT).openConnection() as HttpURLConnection
                conn.connectTimeout = 15000
                conn.readTimeout = 30000
                val total = conn.contentLengthLong.coerceAtLeast(1)
                var done = 0L
                var lastSent = 0L
                conn.inputStream.use { input ->
                    FileOutputStream(zip).use { out ->
                        val buf = ByteArray(64 * 1024)
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            done += n
                            if (done - lastSent > 512 * 1024) {
                                lastSent = done
                                progress = 0.9 * done / total
                                onProgress(progress, null)
                            }
                        }
                    }
                }
                tmp.deleteRecursively()
                tmp.mkdirs()
                ZipInputStream(zip.inputStream().buffered()).use { zin ->
                    while (true) {
                        val e = zin.nextEntry ?: break
                        // Remove a pasta raiz do zip (vosk-model-small-pt-0.3/...).
                        val rel = e.name.substringAfter('/', "")
                        if (rel.isEmpty()) continue
                        val out = File(tmp, rel)
                        if (!out.canonicalPath.startsWith(tmp.canonicalPath)) continue // zip malicioso
                        if (e.isDirectory) out.mkdirs() else {
                            out.parentFile?.mkdirs()
                            FileOutputStream(out).use { zin.copyTo(it) }
                        }
                    }
                }
                dir(ctx).deleteRecursively()
                if (!tmp.renameTo(dir(ctx))) throw IllegalStateException("não consegui instalar o modelo")
                progress = 1.0
                onProgress(1.0, null)
            } catch (e: Exception) {
                tmp.deleteRecursively()
                onProgress(progress, e.message ?: e.toString())
            } finally {
                zip.delete()
                downloading = false
            }
        }
    }
}
