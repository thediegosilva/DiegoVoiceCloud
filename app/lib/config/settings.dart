import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'prompts.dart';

/// Modo de conexão do Jarvis.
enum JarvisMode {
  /// App conecta numa sala LiveKit onde o agente Python (backend/) está rodando.
  /// Todas as ferramentas (PC, casa, memória) rodam no PC do backend.
  livekit,

  /// App conversa direto com a Gemini Live API. As ferramentas rodam no próprio app.
  gemini,
}

/// Configurações persistidas localmente (SharedPreferences).
///
/// Atenção: as chaves ficam salvas em texto puro no dispositivo. É ok para uso
/// pessoal, mas não distribua o app com chaves pré-preenchidas.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);

  final SharedPreferences _prefs;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings._(prefs);
  }

  String _s(String key, String def) => _prefs.getString(key) ?? def;
  bool _b(String key, bool def) => _prefs.getBool(key) ?? def;

  Future<void> _set(String key, Object value) async {
    if (value is String) await _prefs.setString(key, value);
    if (value is bool) await _prefs.setBool(key, value);
    notifyListeners();
  }

  // ── Geral ───────────────────────────────────────────────
  JarvisMode get mode =>
      _s('mode', 'livekit') == 'gemini' ? JarvisMode.gemini : JarvisMode.livekit;
  set mode(JarvisMode v) => _set('mode', v.name);

  String get userId => _s('userId', 'PedroLucas');
  set userId(String v) => _set('userId', v);

  // ── Modo LiveKit ────────────────────────────────────────
  /// URL do token server (backend/token_server.py), ex: http://192.168.0.10:8787
  String get tokenServerUrl => _s('tokenServerUrl', 'http://localhost:8787');
  set tokenServerUrl(String v) => _set('tokenServerUrl', v);

  String get tokenServerPassword => _s('tokenServerPassword', '');
  set tokenServerPassword(String v) => _set('tokenServerPassword', v);

  // ── Modo Gemini direto ─────────────────────────────────
  String get geminiApiKey => _s('geminiApiKey', '');
  set geminiApiKey(String v) => _set('geminiApiKey', v);

  String get geminiModel =>
      _s('geminiModel', 'gemini-2.5-flash-native-audio-preview-12-2025');
  set geminiModel(String v) => _set('geminiModel', v);

  String get geminiVoice => _s('geminiVoice', 'Charon');
  set geminiVoice(String v) => _set('geminiVoice', v);

  /// Vozes femininas do Gemini (as demais são masculinas). Define a cor do
  /// orbe: rosa para feminina, azul para masculina.
  static const femaleVoices = {
    'Kore', 'Aoede', 'Leda', 'Zephyr', 'Autonoe', 'Callirrhoe', 'Despina',
    'Erinome', 'Gacrux', 'Laomedeia', 'Pulcherrima', 'Sulafat', 'Vindemiatrix', 'Achernar',
  };

  bool get voiceIsFemale => femaleVoices.contains(geminiVoice);

  String get systemPrompt => _s('systemPrompt', kAgentInstruction);
  set systemPrompt(String v) => _set('systemPrompt', v);

  /// Não envia o microfone enquanto o Jarvis fala (evita que ele ouça a própria
  /// voz em PCs sem cancelamento de eco). Recomendado em desktop sem fone.
  bool get halfDuplex => _b('halfDuplex', defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows);
  set halfDuplex(bool v) => _set('halfDuplex', v);

  String get mem0ApiKey => _s('mem0ApiKey', '');
  set mem0ApiKey(String v) => _set('mem0ApiKey', v);

  String get voiceMonkeyToken => _s('voiceMonkeyToken', '');
  set voiceMonkeyToken(String v) => _set('voiceMonkeyToken', v);

  /// Ferramentas de controle do PC (só em Linux/Windows).
  bool get pcToolsEnabled => _b('pcToolsEnabled', true);
  set pcToolsEnabled(bool v) => _set('pcToolsEnabled', v);
}
