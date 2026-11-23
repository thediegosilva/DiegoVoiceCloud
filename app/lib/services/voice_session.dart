import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Offset;

enum SessionState { idle, connecting, listening, thinking, speaking, error }

enum ActionStatus { running, ok, failed }

/// Uma ação executada pelo Jarvis (ferramenta), mostrada no painel.
class ActionEntry {
  ActionEntry({required this.id, required this.tool, required this.title, this.detail = ''})
      : started = DateTime.now();

  final String id;
  final String tool;
  final String title;
  final DateTime started;
  String detail;
  String result = '';
  ActionStatus status = ActionStatus.running;
  Duration? took;
}

class ChatMessage {
  ChatMessage({required this.id, required this.fromUser, required this.text, this.isTool = false});

  final String id;
  final bool fromUser;
  String text;

  /// Mensagem de sistema/ferramenta (ex: "🔧 controlar_casa(...)").
  final bool isTool;
}

/// Interface comum aos dois modos (LiveKit e Gemini direto) para a UI.
abstract class VoiceSession extends ChangeNotifier {
  SessionState state = SessionState.idle;
  String? error;
  final List<ChatMessage> messages = [];
  bool micEnabled = true;

  /// Nível de áudio 0..1 do Jarvis (para animar o orbe).
  double agentLevel = 0;

  /// Nível de áudio 0..1 do microfone.
  double userLevel = 0;

  /// Ações do Jarvis (mais recentes no fim).
  final List<ActionEntry> actions = [];

  /// Último quadro (JPEG) que o Jarvis recebeu da tela / da câmera.
  Uint8List? lastScreenFrame;
  Uint8List? lastCameraFrame;

  /// Último clique na tela (0–1000) para marcar no painel.
  /// Proporção (largura/altura) da tela compartilhada.
  double screenAspect = 16 / 9;

  Offset? lastClick;
  DateTime? lastClickAt;

  bool get supportsCamera => false;
  bool cameraEnabled = false;

  /// Alternar câmera frontal/traseira.
  bool get supportsCameraSwitch => false;
  Future<void> switchCamera() async {}

  /// Compartilhar a tela do PC com o Jarvis.
  bool get supportsScreen => false;
  bool screenEnabled = false;

  /// true enquanto espera o usuário aprovar no diálogo do sistema.
  bool screenStarting = false;
  Future<void> setScreenEnabled(bool enabled) async {}

  /// Permitir que o Jarvis use mouse e teclado (só com a tela compartilhada).
  bool get supportsControl => false;
  bool controlEnabled = false;
  Future<void> setControlEnabled(bool enabled) async {}

  Future<void> connect();
  Future<void> disconnect();
  Future<void> sendText(String text);
  Future<void> setMicEnabled(bool enabled);
  Future<void> setCameraEnabled(bool enabled) async {}

  void setState(SessionState s, {String? err}) {
    state = s;
    if (err != null) error = err;
    notifyListeners();
  }

  /// Adiciona ou atualiza (pelo id) uma mensagem da transcrição.
  void upsertMessage(String id, {required bool fromUser, required String text, bool append = false, bool isTool = false}) {
    final idx = messages.indexWhere((m) => m.id == id);
    if (idx == -1) {
      messages.add(ChatMessage(id: id, fromUser: fromUser, text: text, isTool: isTool));
    } else {
      messages[idx].text = append ? messages[idx].text + text : text;
    }
    notifyListeners();
  }
}
