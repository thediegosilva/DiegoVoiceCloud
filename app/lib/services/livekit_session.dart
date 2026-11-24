import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' hide ChatMessage;

import '../config/settings.dart';
import 'voice_session.dart';

/// Modo LiveKit: substitui o frontend Next.js. O app pega um token no
/// backend/token_server.py (protegido por senha), entra numa sala e o agente
/// Python (backend/agent.py) entra automaticamente.
class LiveKitSession extends VoiceSession {
  /// [history]: conversa salva reaberta (só aparece na tela; o agente do PC
  /// não recebe o histórico).
  LiveKitSession({required this.settings, List<ChatMessage> history = const []}) {
    messages.addAll(history);
  }

  final AppSettings settings;

  Room? room;
  EventsListener<RoomEvent>? _listener;
  Timer? _ticker;
  bool _closing = false;

  @override
  bool get supportsCamera => true;

  LocalVideoTrack? get localVideoTrack {
    final pubs = room?.localParticipant?.videoTrackPublications ?? const [];
    for (final p in pubs) {
      if (p.track != null && p.source == TrackSource.camera) return p.track as LocalVideoTrack;
    }
    return null;
  }

  RemoteParticipant? get _agent =>
      room?.remoteParticipants.values.where((p) => p.kind == ParticipantKind.AGENT).firstOrNull ??
      room?.remoteParticipants.values.firstOrNull;

  @override
  Future<void> connect() async {
    _closing = false;
    setState(SessionState.connecting);
    try {
      // 1) Token
      final base = settings.tokenServerUrl.replaceAll(RegExp(r'/+$'), '');
      final res = await http
          .post(
            Uri.parse('$base/token'),
            headers: {
              'Authorization': 'Bearer ${settings.tokenServerPassword}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'identity': settings.userName.isEmpty ? settings.userId : settings.userName,
              'userContext': settings.userContext(),
              'assistantName': settings.assistantName,
              'voice': settings.geminiVoice,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 401) throw Exception('Senha do servidor de token incorreta.');
      if (res.statusCode != 200) throw Exception('Servidor de token respondeu ${res.statusCode}: ${res.body}');
      final details = jsonDecode(res.body) as Map<String, dynamic>;

      // 2) Sala
      final r = Room(
        roomOptions: const RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          defaultAudioCaptureOptions: AudioCaptureOptions(echoCancellation: true, noiseSuppression: true, autoGainControl: true),
        ),
      );
      room = r;
      _listener = r.createListener()
        ..on<RoomDisconnectedEvent>((e) {
          if (!_closing) {
            _cleanup();
            setState(SessionState.error, err: 'Desconectado da sala (${e.reason?.name ?? 'motivo desconhecido'}).');
          }
        })
        ..on<ParticipantAttributesChanged>((_) => _syncAgentState())
        ..on<ParticipantConnectedEvent>((_) => _syncAgentState())
        ..on<ParticipantDisconnectedEvent>((e) {
          if (e.participant.kind == ParticipantKind.AGENT && !_closing) {
            setState(SessionState.error, err: 'O agente saiu da sala.');
          }
        });

      // 3) Transcrições (o agente publica no tópico lk.transcription)
      r.registerTextStreamHandler('lk.transcription', (TextStreamReader reader, String identity) {
        final info = reader.info;
        final key = info?.attributes['lk.segment_id'] ?? info?.id ?? DateTime.now().toIso8601String();
        final fromUser = identity == r.localParticipant?.identity;
        var acc = '';
        reader.listen((chunk) {
          acc += utf8.decode(chunk.content, allowMalformed: true);
          upsertMessage(key, fromUser: fromUser, text: acc);
        });
      });

      await r.connect(details['serverUrl'] as String, details['participantToken'] as String);
      await r.localParticipant?.setMicrophoneEnabled(true);
      micEnabled = true;

      setState(SessionState.thinking); // aguardando o agente entrar
      _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
        agentLevel = _agent?.audioLevel ?? 0;
        userLevel = r.localParticipant?.audioLevel ?? 0;
        notifyListeners();
      });
      _syncAgentState();
    } catch (e) {
      await _cleanup();
      setState(SessionState.error, err: 'Falha ao conectar: $e');
    }
  }

  void _syncAgentState() {
    final a = _agent;
    if (a == null) return;
    final s = a.attributes['lk.agent.state'];
    final newState = switch (s) {
      'speaking' => SessionState.speaking,
      'thinking' || 'initializing' => SessionState.thinking,
      _ => SessionState.listening,
    };
    if (newState != state) setState(newState);
  }

  @override
  Future<void> sendText(String text) async {
    final lp = room?.localParticipant;
    if (lp == null || text.trim().isEmpty) return;
    upsertMessage('chat-${DateTime.now().microsecondsSinceEpoch}', fromUser: true, text: text);
    await lp.sendText(text, options: SendTextOptions(topic: 'lk.chat'));
  }

  @override
  Future<void> setMicEnabled(bool enabled) async {
    await room?.localParticipant?.setMicrophoneEnabled(enabled);
    micEnabled = enabled;
    notifyListeners();
  }

  bool _frontCamera = true;

  @override
  bool get supportsCameraSwitch => Platform.isAndroid || Platform.isIOS;

  @override
  Future<void> switchCamera() async {
    final track = localVideoTrack;
    if (track == null) return;
    _frontCamera = !_frontCamera;
    await track.setCameraPosition(_frontCamera ? CameraPosition.front : CameraPosition.back);
    notifyListeners();
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    try {
      await room?.localParticipant?.setCameraEnabled(enabled);
      cameraEnabled = enabled;
    } catch (e) {
      error = 'Câmera: $e';
    }
    notifyListeners();
  }

  Future<void> _cleanup() async {
    _ticker?.cancel();
    await _listener?.dispose();
    _listener = null;
    room?.unregisterTextStreamHandler('lk.transcription');
    await room?.dispose();
    room = null;
    agentLevel = 0;
    userLevel = 0;
    cameraEnabled = false;
  }

  @override
  Future<void> disconnect() async {
    _closing = true;
    await room?.disconnect();
    await _cleanup();
    setState(SessionState.idle);
  }

  @override
  void dispose() {
    _closing = true;
    _cleanup();
    super.dispose();
  }
}
