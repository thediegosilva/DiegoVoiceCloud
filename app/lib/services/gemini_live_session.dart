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

  int get _now => DateTime.now().millisecondsSinceEpoch;
  bool get _agentSpeaking => _now < _playUntil;

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
        }
      });

      // 3) Saída de áudio
      _player = getAudioStream()
        ..init(sampleRate: _outRate, channels: 1, bufferMilliSec: 120000, waitingBufferMilliSec: 80, fadeOnExhaust: true)
        ..resume();

      _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
    } catch (e) {
      _fail('Falha ao conectar: $e');
    }
  }

  Future<void> _startMic() async {
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _inRate,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
      autoGain: true,
    ));
    _micSub = stream.listen((chunk) {
      userLevel = _rms(chunk);
      if (!micEnabled) return;
      // Half-duplex: não manda o microfone enquanto o Jarvis fala (+300ms)
      if (settings.halfDuplex && _now < _playUntil + 300) return;
      _send({
        'realtimeInput': {
          'audio': {'data': base64Encode(chunk), 'mimeType': 'audio/pcm;rate=$_inRate'}
        }
      });
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
    _playUntil = math.max(_now, _playUntil) + durMs;
  }

  /// Usuário interrompeu: descarta o áudio que ainda não tocou.
  void _flushPlayback() {
    _player?.uninit();
    _player = getAudioStream()
      ..init(sampleRate: _outRate, channels: 1, bufferMilliSec: 120000, waitingBufferMilliSec: 80, fadeOnExhaust: true)
      ..resume();
    _playUntil = _now;
  }

  static double _rms(Uint8List chunk) {
    final view = ByteData.sublistView(chunk);
    final n = chunk.lengthInBytes ~/ 2;
    if (n == 0) return 0;
    double sum = 0;
    for (var i = 0; i < n; i++) {
      final v = view.getInt16(i * 2, Endian.little) / 32768.0;
      sum += v * v;
    }
    return math.min(1, math.sqrt(sum / n) * 5);
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
