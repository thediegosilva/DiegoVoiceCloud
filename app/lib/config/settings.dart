import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/terminal_service.dart';
import 'prompts.dart';

/// Modo de conexão da IA.
enum ConnectionMode {
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
  ConnectionMode get mode =>
      _s('mode', 'gemini') == 'livekit' ? ConnectionMode.livekit : ConnectionMode.gemini; // padrão: Modelo de IA
  set mode(ConnectionMode v) => _set('mode', v.name);

  // ── Usuário (perguntado na primeira abertura) ──────────
  /// Já respondeu as perguntas da primeira abertura?
  bool get onboardingDone => _b('onboardingDone', false);
  set onboardingDone(bool v) => _set('onboardingDone', v);

  /// Como a IA chama o usuário.
  String get userName => _s('userName', '').trim();
  set userName(String v) => _set('userName', v.trim());

  /// Data de nascimento (guardada como aaaa-mm-dd).
  DateTime? get birthDate => DateTime.tryParse(_s('birthDate', ''));
  set birthDate(DateTime? v) => _set('birthDate',
      v == null ? '' : '${v.year.toString().padLeft(4, '0')}-${v.month.toString().padLeft(2, '0')}-${v.day.toString().padLeft(2, '0')}');

  /// ID da memória (Mem0). Se não foi definido, vem do nome do usuário.
  String get userId {
    final id = _prefs.getString('userId')?.trim() ?? '';
    if (id.isNotEmpty) return id;
    final n = normalizeSpeech(userName).replaceAll(' ', '_');
    return n.isEmpty ? 'usuario' : n;
  }

  set userId(String v) => _set('userId', v);

  /// O que a IA sabe do usuário: nome, nascimento, idade e se é aniversário.
  String userContext([DateTime? now]) {
    final today = now ?? DateTime.now();
    final b = StringBuffer('O usuário se chama ${userName.isEmpty ? '(não informado)' : userName}; chame-o assim.');
    final d = birthDate;
    if (d != null) {
      var age = today.year - d.year;
      if (today.month < d.month || (today.month == d.month && today.day < d.day)) age--;
      String two(int n) => n.toString().padLeft(2, '0');
      b.write(' Data de nascimento: ${two(d.day)}/${two(d.month)}/${d.year} ($age anos).');
      b.write(' Hoje é ${two(today.day)}/${two(today.month)}/${today.year}.');
      if (today.month == d.month && today.day == d.day) {
        b.write(' HOJE É ANIVERSÁRIO DO USUÁRIO: deseje feliz aniversário de forma carinhosa logo no começo.');
      }
    }
    return b.toString();
  }

  // ── Modo LiveKit ────────────────────────────────────────
  /// URL do token server (backend/token_server.py), ex: http://192.168.0.10:8787
  String get tokenServerUrl => _s('tokenServerUrl', 'http://localhost:8787');
  set tokenServerUrl(String v) => _set('tokenServerUrl', v);

  String get tokenServerPassword => _s('tokenServerPassword', '');
  set tokenServerPassword(String v) => _set('tokenServerPassword', v);

  // ── Modo Gemini direto ─────────────────────────────────
  static const maxApiKeys = 15;

  /// Chaves da API do Gemini cadastradas (até [maxApiKeys]).
  /// Os nomes são automáticos, pela ordem: "CHAVE API 1", "CHAVE API 2"…
  List<ApiKeyEntry> get geminiKeys {
    final raw = _prefs.getString('geminiKeys');
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        return [
          for (var i = 0; i < list.length; i++)
            ApiKeyEntry.fromJson(list[i] as Map<String, dynamic>).withLabel('CHAVE API ${i + 1}')
        ];
      } catch (_) {}
    }
    // Migração: a chave única da versão anterior vira "Chave 1".
    final legacy = _s('geminiApiKey', '');
    return legacy.isEmpty ? [] : [ApiKeyEntry(id: 'k1', label: 'CHAVE API 1', key: legacy)];
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
  Future<bool> addKey(String key) async {
    final keys = geminiKeys;
    if (keys.length >= maxApiKeys) return false;
    final id = 'k${DateTime.now().microsecondsSinceEpoch}';
    keys.add(ApiKeyEntry(id: id, label: 'CHAVE API ${keys.length + 1}', key: key.trim()));
    await _saveKeys(keys);
    if (keys.length == 1) activeKeyId = id;
    return true;
  }

  Future<void> updateKey(String id, {required String key}) async {
    final keys = [
      for (final k in geminiKeys)
        if (k.id == id) ApiKeyEntry(id: id, label: k.label, key: key.trim()) else k
    ];
    await _saveKeys(keys);
  }

  Future<void> removeKey(String id) async {
    await _saveKeys(geminiKeys.where((k) => k.id != id).toList());
  }

  String get geminiModel =>
      _s('geminiModel', 'gemini-3.8-live');
  set geminiModel(String v) => _set('geminiModel', v);

  String get geminiVoice => _s('geminiVoice', 'Kore'); // padrão: voz feminina (Lexy)
  set geminiVoice(String v) => _set('geminiVoice', v);

  /// Vozes femininas do Gemini (as demais são masculinas). Define a cor do
  /// orbe: rosa para feminina, azul para masculina.
  static const femaleVoices = {
    'Kore', 'Aoede', 'Leda', 'Zephyr', 'Autonoe', 'Callirrhoe', 'Despina',
    'Erinome', 'Gacrux', 'Laomedeia', 'Pulcherrima', 'Sulafat', 'Vindemiatrix', 'Achernar',
  };

  bool get voiceIsFemale => femaleVoices.contains(geminiVoice);

  /// Personalidade, com {NOME} trocado pelo nome atual da IA.
  String get systemPrompt => _s('systemPrompt', kAgentInstruction).replaceAll('{NOME}', assistantName);

  /// Personalidade como foi escrita (com o marcador {NOME}), para editar.
  String get systemPromptTemplate => _s('systemPrompt', kAgentInstruction);
  set systemPrompt(String v) => _set('systemPrompt', v);

  /// Não envia o microfone enquanto a IA fala (evita que ele ouça a própria
  /// voz em PCs sem cancelamento de eco). Recomendado em desktop sem fone.
  bool get halfDuplex => _b('halfDuplex', true); // ligado por padrão em todos os aparelhos
  set halfDuplex(bool v) => _set('halfDuplex', v);

  String get mem0ApiKey => _s('mem0ApiKey', '');
  set mem0ApiKey(String v) => _set('mem0ApiKey', v);

  String get voiceMonkeyToken => _s('voiceMonkeyToken', '');
  set voiceMonkeyToken(String v) => _set('voiceMonkeyToken', v);

  /// Deixa a IA usar mouse e teclado quando a tela estiver compartilhada.
  /// Desligado por padrão: o usuário precisa ativar conscientemente.
  bool get allowComputerControl => _b('allowComputerControl', false);
  set allowComputerControl(bool v) => _set('allowComputerControl', v);

  /// Modelos do agente de uso do computador, em ordem de preferência
  /// (se um estiver sobrecarregado, usa o próximo).
  String get agentModels => _s('agentModels', 'gemini-3.5-flash, gemini-3.8-flash, gemini-flash-latest');
  set agentModels(String v) => _set('agentModels', v);

  List<String> get agentModelList =>
      agentModels.split(',').map((m) => m.trim()).where((m) => m.isNotEmpty).toList();

  /// Uso do terminal pela IA: desligado, perguntar sempre, ou automático
  /// (comandos perigosos sempre perguntam).
  TerminalMode get terminalMode => TerminalMode.values.firstWhere(
      (m) => m.name == _s('terminalMode', 'ask'), orElse: () => TerminalMode.ask);
  set terminalMode(TerminalMode v) => _set('terminalMode', v.name);

  /// Ferramentas de controle do PC (só em Linux/Windows).
  bool get pcToolsEnabled => _b('pcToolsEnabled', true);
  set pcToolsEnabled(bool v) => _set('pcToolsEnabled', v);

  // ── Assistente (nome e palavra de ativação) ─────────────
  /// Nomes prontos para escolher (também são palavras de ativação testadas).
  static const presetMaleNames = ['Diego'];
  static const presetFemaleNames = ['Lexy'];

  /// Nome da IA quando a voz é masculina.
  String get maleName {
    final n = _s('maleName', 'Diego').trim();
    return n.isEmpty ? 'Diego' : n;
  }

  set maleName(String v) => _set('maleName', v);

  /// Nome da IA quando a voz é feminina.
  String get femaleName {
    final n = _s('femaleName', 'Lexy').trim();
    return n.isEmpty ? 'Lexy' : n;
  }

  set femaleName(String v) => _set('femaleName', v);

  /// Nome atual da IA: muda junto com a voz (masculina → [maleName],
  /// feminina → [femaleName]). É como ela se apresenta e a palavra que a acorda.
  String get assistantName => voiceIsFemale ? femaleName : maleName;

  /// Acordar pela voz com a tela apagada (Android).
  bool get wakeWordEnabled => _b('wakeWordEnabled', false);
  set wakeWordEnabled(bool v) => _set('wakeWordEnabled', v);

  /// Sensibilidade alta: acorda mais fácil (inclusive por engano).
  bool get wakeHighSensitivity => _b('wakeHighSensitivity', false);
  set wakeHighSensitivity(bool v) => _set('wakeHighSensitivity', v);

  String get _aliasKey => 'wakeAliases_${normalizeSpeech(assistantName)}';

  /// Outras formas de escrever como o reconhecedor offline ouve o nome ATUAL
  /// (cada nome tem as suas). Separadas por vírgula.
  String get wakeAliases => _s(_aliasKey, '');
  set wakeAliases(String v) => _set(_aliasKey, v);

  /// Frases que acordam a IA: o nome + as variações cadastradas, em
  /// minúsculas e com acentos (o reconhecedor usa as palavras com acento).
  List<String> get wakePhrases {
    final all = [assistantName, ...wakeAliases.split(','), ...?_soundsLike[normalizeSpeech(assistantName)]];
    final out = <String>[];
    for (final p in all) {
      final n = p.toLowerCase().replaceAll(RegExp(r'[-.,!?;:"]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (n.isNotEmpty && !out.contains(n)) out.add(n);
    }
    return out;
  }

  /// Nomes que o reconhecedor offline em português não conhece, e a palavra
  /// parecida que ele conhece e costuma ouvir no lugar.
  /// Medido com o modelo pt-BR: "Lexy" é transcrito como "léxico" (24/24
  /// acertos com voz sintética, sem alarmes falsos em frases comuns).
  static const _soundsLike = {
    'lexy': ['léxico'],
    'lexi': ['léxico'],
    'lexie': ['léxico'],
    'alexa': ['alexia'],
  };

  /// Encerra a conversa do modo assistente após este silêncio (segundos).
  int get wakeIdleSeconds => _prefs.getInt('wakeIdleSeconds') ?? 30;
  set wakeIdleSeconds(int v) {
    _prefs.setInt('wakeIdleSeconds', v);
    notifyListeners();
  }

  // ── Rede entre aparelhos (Elo) ──────────────────────────
  bool get meshEnabled => _b('meshEnabled', false);
  set meshEnabled(bool v) => _set('meshEnabled', v);

  /// Código secreto compartilhado só entre os seus aparelhos.
  String get meshCode => _s('meshCode', '');
  set meshCode(String v) => _set('meshCode', v);

  /// Como este aparelho se chama na rede (ex.: "iPhone", "Android", "PC").
  String get deviceName {
    final n = _s('deviceName', '').trim();
    if (n.isNotEmpty) return n;
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'iPhone',
      TargetPlatform.android => 'Android',
      _ => 'PC',
    };
  }

  set deviceName(String v) => _set('deviceName', v);

  /// Quando chega um recado sem conversa aberta, abre o assistente e fala
  /// em voz alta (no Android, acende a tela). Desligado = só um aviso.
  bool get meshSpeakNotes => _b('meshSpeakNotes', true);
  set meshSpeakNotes(bool v) => _set('meshSpeakNotes', v);

  /// Servidores de recados (MQTT com TLS), em ordem de preferência.
  String get meshBrokers => _s('meshBrokers', 'broker.emqx.io:8883, broker.hivemq.com:8883');
  set meshBrokers(String v) => _set('meshBrokers', v);

  /// Id fixo e aleatório desta instalação (para ignorar os próprios ecos).
  String get installId {
    var id = _prefs.getString('installId');
    if (id == null) {
      final r = Random.secure();
      id = List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      _prefs.setString('installId', id);
    }
    return id;
  }
}

/// Minúsculas, sem acentos e sem pontuação — para comparar o que foi falado.
String normalizeSpeech(String s) {
  const from = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
  const to = 'aaaaaeeeeiiiiooooouuuucn';
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
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

  ApiKeyEntry withLabel(String l) => ApiKeyEntry(id: id, label: l, key: key);

  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'key': key};
}
