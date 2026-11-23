import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/terminal_service.dart';
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
  static const maxApiKeys = 15;

  /// Chaves da API do Gemini cadastradas (até [maxApiKeys]).
  List<ApiKeyEntry> get geminiKeys {
    final raw = _prefs.getString('geminiKeys');
    if (raw != null) {
      try {
        return [for (final e in jsonDecode(raw) as List) ApiKeyEntry.fromJson(e as Map<String, dynamic>)];
      } catch (_) {}
    }
    // Migração: a chave única da versão anterior vira "Chave 1".
    final legacy = _s('geminiApiKey', '');
    return legacy.isEmpty ? [] : [ApiKeyEntry(id: 'k1', label: 'Chave 1', key: legacy)];
  }

  Future<void> _saveKeys(List<ApiKeyEntry> keys) async {
    await _prefs.setString('geminiKeys', jsonEncode([for (final k in keys) k.toJson()]));
    await _prefs.remove('geminiApiKey');
    notifyListeners();
  }

  String get activeKeyId {
    final keys = geminiKeys;
    final id = _prefs.getString('geminiActiveKey');
    if (keys.any((k) => k.id == id)) return id!;
    return keys.isEmpty ? '' : keys.first.id;
  }

  set activeKeyId(String id) => _set('geminiActiveKey', id);

  ApiKeyEntry? get activeKey {
    final id = activeKeyId;
    for (final k in geminiKeys) {
      if (k.id == id) return k;
    }
    return null;
  }

  /// Chave em uso nas chamadas ao Gemini.
  String get geminiApiKey => activeKey?.key ?? '';

  /// Adiciona uma chave. Retorna false se já houver [maxApiKeys].
  Future<bool> addKey(String label, String key) async {
    final keys = geminiKeys;
    if (keys.length >= maxApiKeys) return false;
    final id = 'k${DateTime.now().microsecondsSinceEpoch}';
    keys.add(ApiKeyEntry(id: id, label: label.trim().isEmpty ? 'Chave ${keys.length + 1}' : label.trim(), key: key.trim()));
    await _saveKeys(keys);
    if (keys.length == 1) activeKeyId = id;
    return true;
  }

  Future<void> updateKey(String id, {required String label, required String key}) async {
    final keys = [
      for (final k in geminiKeys)
        if (k.id == id) ApiKeyEntry(id: id, label: label.trim().isEmpty ? k.label : label.trim(), key: key.trim()) else k
    ];
    await _saveKeys(keys);
  }

  Future<void> removeKey(String id) async {
    await _saveKeys(geminiKeys.where((k) => k.id != id).toList());
  }

  String get geminiModel =>
      _s('geminiModel', 'gemini-3.8-live');
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

  /// Deixa o Jarvis usar mouse e teclado quando a tela estiver compartilhada.
  /// Desligado por padrão: o usuário precisa ativar conscientemente.
  bool get allowComputerControl => _b('allowComputerControl', false);
  set allowComputerControl(bool v) => _set('allowComputerControl', v);

  /// Modelos do agente de uso do computador, em ordem de preferência
  /// (se um estiver sobrecarregado, usa o próximo).
  String get agentModels => _s('agentModels', 'gemini-3.5-flash, gemini-3.8-flash, gemini-flash-latest');
  set agentModels(String v) => _set('agentModels', v);

  List<String> get agentModelList =>
      agentModels.split(',').map((m) => m.trim()).where((m) => m.isNotEmpty).toList();

  /// Uso do terminal pelo Jarvis: desligado, perguntar sempre, ou automático
  /// (comandos perigosos sempre perguntam).
  TerminalMode get terminalMode => TerminalMode.values.firstWhere(
      (m) => m.name == _s('terminalMode', 'ask'), orElse: () => TerminalMode.ask);
  set terminalMode(TerminalMode v) => _set('terminalMode', v.name);

  /// Ferramentas de controle do PC (só em Linux/Windows).
  bool get pcToolsEnabled => _b('pcToolsEnabled', true);
  set pcToolsEnabled(bool v) => _set('pcToolsEnabled', v);
}

/// Uma chave de API salva, com um apelido para o usuário reconhecer.
@immutable
class ApiKeyEntry {
  const ApiKeyEntry({required this.id, required this.label, required this.key});

  factory ApiKeyEntry.fromJson(Map<String, dynamic> j) =>
      ApiKeyEntry(id: j['id'] as String, label: j['label'] as String, key: j['key'] as String);

  final String id;
  final String label;
  final String key;

  /// Ex.: "AIza••••••x9Q2" — nunca mostra a chave inteira na tela.
  String get masked => key.length <= 8 ? '••••' : '${key.substring(0, 4)}••••••${key.substring(key.length - 4)}';

  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'key': key};
}
