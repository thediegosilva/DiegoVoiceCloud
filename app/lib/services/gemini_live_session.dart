import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:camera/camera.dart' show CameraController;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Offset;
import 'package:mp_audio_stream/mp_audio_stream.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/prompts.dart';
import '../config/settings.dart';
import 'camera_feed.dart';
import 'computer_agent.dart';
import 'mem0_service.dart';
import 'screen_bridge.dart';
import 'tool_registry.dart';
import 'voice_session.dart';

/// Modo "Gemini direto": o app fala com a Gemini Live API via WebSocket,
/// sem LiveKit e sem backend Python. Microfone em PCM16 16 kHz, resposta em
/// PCM16 24 kHz.
class GeminiLiveSession extends VoiceSession {
  GeminiLiveSession({required this.settings, required this.tools, required this.mem0}) {
    tools.screen = () => _screen;
    tools.controlAllowed = () => controlEnabled;
    tools.runComputerTask = _runComputerTask;
    controlEnabled = settings.allowComputerControl;
  }

  final AppSettings settings;
  final ToolRegistry tools;
  final Mem0Service mem0;

  static const _inRate = 16000;
  static const _outRate = 24000;

  /// Áudio acumulado antes de começar a tocar (absorve oscilações da rede).
  static const _playerPrebufferMs = 250;

  /// Depois que o Jarvis termina de falar, ainda pode haver eco no ar
  /// (latência do alto-falante + reverberação do ambiente).
  static const _echoTailMs = 450;

  /// Filtro de eco: enquanto o Jarvis fala, o microfone só é liberado se o
  /// usuário falar alto (RMS bruto acima disto) por [_bargeInMs] seguidos.
  /// O eco que sobra depois do cancelamento do sistema fica bem abaixo disso.
  static const _bargeInRms = 0.06;
  static const _bargeInMs = 280;

  /// Guarda os últimos ms de microfone enquanto está bloqueado, para não
  /// perder o começo da frase quando o usuário interrompe.
  static const _preRollMs = 400;

  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  AudioStream? _player;
  Timer? _ticker;

  /// Momento (ms) em que o áudio já enfileirado termina de tocar.
  int _playUntil = 0;
  double _lastOutLevel = 0;
  bool _closing = false;
  bool _setupDone = false;

  String? _userMsgId;
  String? _agentMsgId;
  int _seq = 0;

  // Visão: câmera do celular ou tela do PC
  CameraFeed? _camera;
  ScreenBridge? _screen;
  StreamSubscription<Uint8List>? _visionSub;

  CameraController? get cameraController => _camera?.controller;

  // Estado do filtro de eco
  int _loudSinceMs = 0; // início da sequência atual de microfone alto (0 = nenhuma)
  bool _bargedIn = false; // usuário já interrompeu esta fala do Jarvis
  final List<Uint8List> _preRoll = [];
  int _preRollBytes = 0;

  int get _now => DateTime.now().millisecondsSinceEpoch;
  bool get _agentSpeaking => _now < _playUntil;
  bool get _echoWindow => _now < _playUntil + _echoTailMs;

  @override
  Future<void> connect() async {
    if (settings.geminiApiKey.isEmpty) {
      setState(SessionState.error, err: 'Configure a chave da API do Gemini nas configurações.');
      return;
    }
    _closing = false;
    setState(SessionState.connecting);

    try {
      if (!await _recorder.hasPermission()) {
        setState(SessionState.error, err: 'Permissão de microfone negada.');
        return;
      }

      // 1) Memórias de longo prazo
      final memorias = await mem0.loadMemories(settings.userId);
      var instructions = '${settings.systemPrompt}\n\n$kSessionInstruction\n\n'
          'O nome do usuário é ${settings.userId}.';
      instructions += '\n\n$_visionInstruction';
      if (memorias.isNotEmpty) {
        instructions += '\n\n[Memória carregada — informações sobre o usuário]\n${memorias.map((m) => '- $m').join('\n')}';
      }

      // 2) WebSocket
      final uri = Uri.parse(
          'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent'
          '?key=${Uri.encodeQueryComponent(settings.geminiApiKey)}');
      _ws = WebSocketChannel.connect(uri);
      await _ws!.ready;
      _wsSub = _ws!.stream.listen(_onMessage, onDone: _onClosed, onError: (e) => _fail('Erro de conexão: $e'));

      final decls = tools.declarations;
      _send({
        'setup': {
          'model': 'models/${settings.geminiModel}',
          'generationConfig': {
            'responseModalities': ['AUDIO'],
            'temperature': 0.6,
            'speechConfig': {
              'voiceConfig': {
                'prebuiltVoiceConfig': {'voiceName': settings.geminiVoice}
              }
            },
          },
          'systemInstruction': {
            'parts': [
              {'text': instructions}
            ]
          },
          if (decls.isNotEmpty)
            'tools': [
              {'functionDeclarations': decls}
            ],
          // Sessões com vídeo duram só ~2 min sem compressão de contexto.
          'contextWindowCompression': {'slidingWindow': {}},
          'inputAudioTranscription': {},
          'outputAudioTranscription': {},
          // Responde mais rápido: considera que o usuário terminou após
          // ~0,5 s de silêncio (o padrão do servidor é bem mais longo).
          'realtimeInputConfig': {
            'automaticActivityDetection': {
              'endOfSpeechSensitivity': 'END_SENSITIVITY_HIGH',
              'silenceDurationMs': 500,
              'prefixPaddingMs': 200,
            }
          },
        }
      });

      // 3) Saída de áudio
      _player = _newPlayer();

      _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
    } catch (e) {
      _fail('Falha ao conectar: $e');
    }
  }

  static AudioStream _newPlayer() => getAudioStream()
    ..init(
        sampleRate: _outRate,
        channels: 1,
        bufferMilliSec: 120000,
        waitingBufferMilliSec: _playerPrebufferMs,
        fadeOnExhaust: true)
    ..resume();

  Future<void> _startMic() async {
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _inRate,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
      autoGain: true,
      // No Android o cancelamento de eco do sistema só age de verdade no
      // modo "chamada de voz". Sem isso, a voz do Jarvis volta pelo microfone.
      androidConfig: AndroidRecordConfig(
        audioSource: AndroidAudioSource.voiceCommunication,
        audioManagerMode: AudioManagerMode.modeInCommunication,
        speakerphone: true, // no modo chamada, mantém o som no alto-falante
      ),
    ));
    _micSub = stream.listen(_onMicChunk);
  }

  void _onMicChunk(Uint8List chunk) {
    final level = _rawRms(chunk);
    userLevel = math.min(1, level * 5);
    if (!micEnabled) return;

    if (!_echoWindow) {
      // Jarvis calado: microfone liberado normalmente.
      _resetEchoGate();
      _sendAudio(chunk);
      return;
    }

    // Jarvis falando (ou eco ainda no ar).
    if (_bargedIn) {
      _sendAudio(chunk);
      return;
    }

    _remember(chunk);
    if (!settings.halfDuplex && level >= _bargeInRms) {
      if (_loudSinceMs == 0) _loudSinceMs = _now;
      if (_now - _loudSinceMs >= _bargeInMs) {
        // Usuário está mesmo falando por cima: libera e manda o começo guardado.
        _bargedIn = true;
        for (final c in _preRoll) {
          _sendAudio(c);
        }
        _preRoll.clear();
        _preRollBytes = 0;
        return;
      }
    } else {
      _loudSinceMs = 0;
    }
    // Bloqueado: manda silêncio no lugar, para o detector de fala do servidor
    // perceber que ninguém está falando (em vez de ouvir o eco).
    _sendAudio(Uint8List(chunk.lengthInBytes));
  }

  static const _visionInstruction = '''# Visão e controle do PC
- Quando o usuário ativar a câmera ou o compartilhamento de tela, você recebe imagens ao vivo. Use-as para responder sobre o que ele está mostrando.
- Se perguntarem o que você vê e não houver imagem, diga que a câmera/tela está desligada.
- Para QUALQUER tarefa no computador (abrir site/programa, pesquisar, clicar, tocar vídeo, preencher, organizar), chame executar_tarefa_no_pc com o objetivo COMPLETO e detalhado, incluindo o resultado final esperado (ex.: "...e colocar um dos vídeos para tocar"). Não divida em várias chamadas.
- Antes de chamar, diga só uma frase curta (ex.: "Certo, já vou fazer."). Depois, conte o resultado em uma ou duas frases. Se o resultado trouxer uma pergunta, faça a pergunta ao usuário e chame de novo com a resposta.
- Para comandos simples de terminal você pode usar executar_comando direto.
- Nunca apague, compre, envie mensagens ou altere senhas sem o usuário pedir explicitamente.''';

  ComputerAgent? _agent;

  @override
  Future<void> cancelTask() async {
    _agent?.cancel();
  }

  Future<String> _runComputerTask(String goal) async {
    if (!supportsControl) return 'Uso do computador indisponível (ative as ferramentas de PC nas configurações).';
    if (!controlEnabled) {
      return 'O usuário ainda não permitiu o controle de mouse e teclado. Peça para ele tocar no botão do mouse na chamada.';
    }
    if (!screenEnabled || _screen?.control != true) {
      await setScreenEnabled(true);
      if (!screenEnabled) return 'Não consegui compartilhar a tela com controle.';
    }
    final keys = settings.geminiKeys.map((k) => k.key).toList();
    final active = settings.geminiApiKey;
    keys
      ..remove(active)
      ..insert(0, active);
    final agent = ComputerAgent(
      bridge: _screen!,
      apiKeys: keys,
      models: settings.agentModelList,
      terminal: tools.terminal,
    );
    _agent = agent;
    taskRunning = true;
    taskGoal = goal;
    final head = ActionEntry(id: 'task${_seq++}', tool: 'tarefa', title: 'Tarefa: $goal');
    actions.add(head);
    notifyListeners();

    ActionEntry? current;
    final sw = Stopwatch()..start();
    void finishCurrent() {
      if (current != null && current!.status == ActionStatus.running) {
        current!
          ..status = ActionStatus.ok
          ..took = DateTime.now().difference(current!.started);
      }
    }

    String result;
    try {
      result = await agent.run(goal, onStep: (step) {
        finishCurrent();
        current = ActionEntry(id: 'st${_seq++}', tool: 'passo', title: step.title, detail: step.detail);
        actions.add(current!);
        if (actions.length > 300) actions.removeAt(0);
        if (step.click != null) {
          lastClick = Offset(step.click!.$1, step.click!.$2);
          lastClickAt = DateTime.now();
        }
        notifyListeners();
      });
    } catch (e) {
      result = 'Erro na tarefa: $e';
    }
    finishCurrent();
    head
      ..took = sw.elapsed
      ..result = result
      ..status = result.startsWith('Concluído') ? ActionStatus.ok : ActionStatus.failed;
    _agent = null;
    taskRunning = false;
    taskGoal = '';
    notifyListeners();
    return result;
  }

  static double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

  static bool _looksFailed(String r) {
    final l = r.toLowerCase();
    return l.startsWith('falhou') || l.startsWith('erro') || l.contains('recusou') || l.contains('não consegui') ||
        l.contains('desativad') || l.contains('não permitiu') || l.contains('não está') ||
        RegExp(r'código de saída: [1-9]').hasMatch(l) || l.contains('interrompido após');
  }

  static String _actionTitle(String name, Map<String, dynamic> a) => switch (name) {
        'tela_clicar' => 'Clique ${a['botao'] ?? 'esquerdo'}${'${a['duplo']}'.startsWith('s') ? ' duplo' : ''} em (${a['x']}, ${a['y']})',
        'tela_digitar' => 'Digitar texto',
        'tela_tecla' => 'Tecla ${a['combinacao']}',
        'tela_rolar' => 'Rolar ${a['direcao'] ?? 'baixo'}',
        'executar_comando' => 'Terminal',
        'pesquisar_na_web' => 'Pesquisar: ${a['consulta']}',
        'controlar_casa' => 'Casa: ${a['acao'] ?? 'ligar'} ${a['dispositivo']}',
        _ => name.replaceAll('_', ' '),
      };

  static String _actionDetail(String name, Map<String, dynamic> a) => switch (name) {
        'executar_comando' => '\$ ${a['comando']}',
        'tela_digitar' => '"${a['texto']}"',
        _ => a.isEmpty ? '' : a.entries.map((e) => '${e.key}: ${e.value}').join(' · '),
      };

  void _onScreenFrame(Uint8List jpeg) {
    lastScreenFrame = jpeg;
    _sendImage(jpeg);
    notifyListeners();
  }

  void _onCameraFrame(Uint8List jpeg) {
    lastCameraFrame = jpeg;
    _sendImage(jpeg);
    notifyListeners();
  }

  void _sendImage(Uint8List jpeg) {
    if (!_setupDone) return;
    _send({
      'realtimeInput': {
        'video': {'data': base64Encode(jpeg), 'mimeType': 'image/jpeg'}
      }
    });
  }

  Future<void> _stopVision() async {
    await _visionSub?.cancel();
    _visionSub = null;
    final cam = _camera;
    _camera = null;
    await cam?.dispose();
    final scr = _screen;
    _screen = null;
    await scr?.dispose();
    cameraEnabled = false;
    screenEnabled = false;
    screenStarting = false;
    lastScreenFrame = null;
    lastCameraFrame = null;
  }

  void _note(String text) => upsertMessage('n${_seq++}', fromUser: false, text: text, isTool: true);

  // ── Câmera (celular) ─────────────────────────────────────
  @override
  bool get supportsCamera => CameraFeed.supported;

  @override
  bool get supportsCameraSwitch => CameraFeed.supported;

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    await _stopVision();
    if (enabled) {
      final cam = CameraFeed();
      try {
        await cam.start();
        _camera = cam;
        _visionSub = cam.frames.listen(_onCameraFrame);
        cameraEnabled = true;
      } catch (e) {
        await cam.dispose();
        _note('📷 Não consegui abrir a câmera: $e');
      }
    }
    notifyListeners();
  }

  @override
  Future<void> switchCamera() async {
    final cam = _camera;
    if (cam == null) return;
    try {
      await cam.switchLens();
    } catch (e) {
      _note('📷 Não consegui trocar a câmera: $e');
    }
    notifyListeners();
  }

  // ── Tela do PC ───────────────────────────────────────────
  @override
  bool get supportsScreen => ScreenBridge.supported;

  @override
  bool get supportsControl => ScreenBridge.supported && settings.pcToolsEnabled;

  @override
  Future<void> setScreenEnabled(bool enabled) async {
    await _stopVision();
    if (enabled) {
      screenStarting = true;
      notifyListeners();
      final bridge = ScreenBridge(control: controlEnabled && supportsControl);
      try {
        await bridge.start();
        _screen = bridge;
        screenAspect = bridge.width / bridge.height;
        _visionSub = bridge.frames.listen(_onScreenFrame);
        screenEnabled = true;
        bridge.onClosed = (err) {
          if (_screen != bridge) return;
          _screen = null;
          screenEnabled = false;
          if (err != null) _note('🖥️ $err');
          notifyListeners();
        };
      } catch (e) {
        await bridge.dispose();
        _note('🖥️ Compartilhamento de tela não iniciou: ${e.toString().replaceFirst('Exception: ', '')}');
      }
      screenStarting = false;
    }
    notifyListeners();
  }

  @override
  Future<void> setControlEnabled(bool enabled) async {
    controlEnabled = enabled;
    settings.allowComputerControl = enabled;
    notifyListeners();
    // A permissão de controle muda o tipo de sessão no sistema: reinicia a tela.
    if (screenEnabled && _screen?.control != enabled) await setScreenEnabled(true);
  }

  void _remember(Uint8List chunk) {
    _preRoll.add(chunk);
    _preRollBytes += chunk.lengthInBytes;
    const maxBytes = _inRate * 2 * _preRollMs ~/ 1000;
    while (_preRollBytes > maxBytes && _preRoll.length > 1) {
      _preRollBytes -= _preRoll.removeAt(0).lengthInBytes;
    }
  }

  void _resetEchoGate() {
    _bargedIn = false;
    _loudSinceMs = 0;
    if (_preRoll.isNotEmpty) {
      _preRoll.clear();
      _preRollBytes = 0;
    }
  }

  void _sendAudio(Uint8List pcm) {
    _send({
      'realtimeInput': {
        'audio': {'data': base64Encode(pcm), 'mimeType': 'audio/pcm;rate=$_inRate'}
      }
    });
  }

  void _tick() {
    if (state == SessionState.connecting || state == SessionState.error || state == SessionState.idle) return;
    final speaking = _agentSpeaking;
    agentLevel = speaking ? _lastOutLevel : agentLevel * 0.6;
    if (speaking && state != SessionState.speaking) {
      state = SessionState.speaking;
    } else if (!speaking && state == SessionState.speaking) {
      state = SessionState.listening;
    }
    notifyListeners();
  }

  void _send(Map<String, dynamic> msg) {
    if (_ws == null || _closing) return;
    _ws!.sink.add(jsonEncode(msg));
  }

  Future<void> _onMessage(dynamic raw) async {
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw is String ? raw : utf8.decode(raw as List<int>)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    if (msg.containsKey('setupComplete')) {
      _setupDone = true;
      try {
        await _startMic();
      } catch (e) {
        final msg = e.toString();
        _fail(msg.contains('parecord')
            ? 'Microfone indisponível: falta o programa "parecord" no Linux. '
                'Instale com: sudo apt install pulseaudio-utils'
            : 'Não consegui abrir o microfone: $msg');
        return;
      }
      setState(SessionState.listening);
      // Saudação inicial (igual ao generate_reply do agent.py)
      _send({
        'clientContent': {
          'turns': [
            {
              'role': 'user',
              'parts': [
                {'text': 'Cumprimente o usuário de forma breve e confiante.'}
              ]
            }
          ],
          'turnComplete': true,
        }
      });
      return;
    }

    final sc = msg['serverContent'] as Map<String, dynamic>?;
    if (sc != null) {
      if (sc['interrupted'] == true) _flushPlayback();

      final inT = (sc['inputTranscription'] as Map?)?['text'] as String?;
      if (inT != null && inT.isNotEmpty) {
        _userMsgId ??= 'u${_seq++}';
        upsertMessage(_userMsgId!, fromUser: true, text: inT, append: true);
        if (state == SessionState.listening) setState(SessionState.thinking);
      }

      final outT = (sc['outputTranscription'] as Map?)?['text'] as String?;
      if (outT != null && outT.isNotEmpty) {
        _userMsgId = null;
        _agentMsgId ??= 'a${_seq++}';
        upsertMessage(_agentMsgId!, fromUser: false, text: outT, append: true);
      }

      final parts = (sc['modelTurn'] as Map?)?['parts'] as List?;
      for (final part in parts ?? const []) {
        final data = (part as Map)['inlineData'] as Map?;
        if (data != null && (data['mimeType'] as String? ?? '').startsWith('audio/pcm')) {
          _playPcm(base64Decode(data['data'] as String));
        }
      }

      if (sc['turnComplete'] == true) {
        _agentMsgId = null;
        _userMsgId = null;
      }
    }

    final toolCall = msg['toolCall'] as Map<String, dynamic>?;
    if (toolCall != null) {
      final responses = <Map<String, dynamic>>[];
      for (final call in (toolCall['functionCalls'] as List? ?? const [])) {
        final name = call['name'] as String;
        final args = (call['args'] as Map?)?.cast<String, dynamic>() ?? {};
        final toolId = 't${_seq++}';
        final entry = ActionEntry(id: toolId, tool: name, title: _actionTitle(name, args), detail: _actionDetail(name, args));
        // A tarefa do agente tem seu próprio registro detalhado (passo a passo).
        if (name != 'executar_tarefa_no_pc') actions.add(entry);
        if (actions.length > 300) actions.removeAt(0);
        if (name == 'tela_clicar') {
          lastClick = Offset(_num(args['x']), _num(args['y']));
          lastClickAt = DateTime.now();
        }
        upsertMessage(toolId, fromUser: false, text: '⚙️ ${entry.title}…', isTool: true);
        final sw = Stopwatch()..start();
        final result = await tools.execute(name, args);
        entry
          ..took = sw.elapsed
          ..result = result
          ..status = _looksFailed(result) ? ActionStatus.failed : ActionStatus.ok;
        upsertMessage(toolId, fromUser: false,
            text: '${entry.status == ActionStatus.ok ? '✅' : '⚠️'} ${entry.title}', isTool: true);
        responses.add({
          'id': call['id'],
          'name': name,
          'response': {'result': result},
        });
      }
      _send({
        'toolResponse': {'functionResponses': responses}
      });
    }

    if (msg.containsKey('goAway')) {
      debugPrint('[Gemini] goAway: ${msg['goAway']}');
    }
  }

  void _playPcm(Uint8List bytes) {
    final p = _player;
    if (p == null) return;
    final samples = bytes.lengthInBytes ~/ 2;
    final view = ByteData.sublistView(bytes);
    final out = Float32List(samples);
    double sum = 0;
    for (var i = 0; i < samples; i++) {
      final v = view.getInt16(i * 2, Endian.little) / 32768.0;
      out[i] = v;
      sum += v * v;
    }
    p.push(out);
    _lastOutLevel = math.min(1, math.sqrt(sum / math.max(1, samples)) * 4);
    final durMs = samples * 1000 ~/ _outRate;
    // Se o player estava parado, ele espera juntar o pré-buffer antes de tocar.
    final start = _playUntil > _now ? _playUntil : _now + _playerPrebufferMs;
    _playUntil = start + durMs;
  }

  /// Usuário interrompeu: descarta o áudio que ainda não tocou.
  void _flushPlayback() {
    _player?.uninit();
    _player = _newPlayer();
    _playUntil = _now;
  }

  static double _rawRms(Uint8List chunk) {
    final view = ByteData.sublistView(chunk);
    final n = chunk.lengthInBytes ~/ 2;
    if (n == 0) return 0;
    double sum = 0;
    for (var i = 0; i < n; i++) {
      final v = view.getInt16(i * 2, Endian.little) / 32768.0;
      sum += v * v;
    }
    return math.sqrt(sum / n);
  }

  void _onClosed() {
    if (_closing) return;
    final reason = _ws?.closeReason;
    _fail(_setupDone
        ? 'Conexão encerrada pelo servidor${reason != null && reason.isNotEmpty ? ': $reason' : '.'}'
        : 'O Gemini recusou a conexão${reason != null && reason.isNotEmpty ? ': $reason' : ''}. Verifique a chave e o modelo.');
  }

  void _fail(String err) {
    _teardown();
    setState(SessionState.error, err: err);
  }

  @override
  Future<void> sendText(String text) async {
    if (text.trim().isEmpty) return;
    upsertMessage('u${_seq++}', fromUser: true, text: text);
    _send({
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': text}
            ]
          }
        ],
        'turnComplete': true,
      }
    });
    setState(SessionState.thinking);
  }

  @override
  Future<void> setMicEnabled(bool enabled) async {
    micEnabled = enabled;
    notifyListeners();
  }

  Future<void> _teardown() async {
    _closing = true;
    _ticker?.cancel();
    await _stopVision();
    await _micSub?.cancel();
    _micSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    await _wsSub?.cancel();
    await _ws?.sink.close();
    _ws = null;
    _player?.uninit();
    _player = null;
    agentLevel = 0;
    userLevel = 0;
  }

  @override
  Future<void> disconnect() async {
    await _teardown();
    // Salva a conversa no Mem0 (igual ao shutdown_hook do Python)
    final conversa = [
      for (final m in messages)
        if (!m.isTool && m.text.trim().isNotEmpty) {'role': m.fromUser ? 'user' : 'assistant', 'content': m.text.trim()}
    ];
    unawaited(mem0.saveConversation(settings.userId, conversa));
    setState(SessionState.idle);
  }

  @override
  void dispose() {
    _teardown();
    _recorder.dispose();
    super.dispose();
  }
}
