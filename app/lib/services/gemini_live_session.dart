import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mp_audio_stream/mp_audio_stream.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/prompts.dart';
import '../config/settings.dart';
import 'mem0_service.dart';
import 'tool_registry.dart';
import 'voice_session.dart';

/// Modo "Gemini direto": o app fala com a Gemini Live API via WebSocket,
/// sem LiveKit e sem backend Python. Microfone em PCM16 16 kHz, resposta em
/// PCM16 24 kHz.
class GeminiLiveSession extends VoiceSession {
  GeminiLiveSession({required this.settings, required this.tools, required this.mem0});

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
      await _startMic();
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
        upsertMessage(toolId, fromUser: false, text: '🔧 $name(${args.values.join(', ')})', isTool: true);
        final result = await tools.execute(name, args);
        upsertMessage(toolId, fromUser: false, text: '🔧 $name → $result', isTool: true);
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
