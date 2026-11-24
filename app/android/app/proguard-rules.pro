# Vosk (reconhecimento offline) usa JNA, que acessa classes/métodos por reflexão.
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class org.vosk.** { *; }
-dontwarn java.awt.**
-dontwarn com.sun.jna.**
# Interface nativa extra (vosk_model_find_word) e serviços do app.
-keep class com.diegovoicecloud.diego_voice_cloud.** { *; }
