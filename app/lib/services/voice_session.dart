import 'package:flutter/foundation.dart';

enum SessionState { idle, connecting, listening, thinking, speaking, error }

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
