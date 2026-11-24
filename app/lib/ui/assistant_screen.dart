import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../services/voice_session.dart';
import 'assistant_logo.dart';

/// Modo assistente (estilo Siri): aberto pela palavra de ativação.
/// Tela escura, o que foi dito em cima e a logo pulsando embaixo.
/// Fecha sozinho depois de [idleSeconds] sem ninguém falar.
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, required this.session, required this.name, this.idleSeconds = 10});

  final VoiceSession session;
  final String name;
  final int idleSeconds;

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  VoiceSession get s => widget.session;
  Timer? _idle;
  /// Meios segundos sem ninguém falar (o timer roda a cada 500 ms).
  int _quietTicks = 0;
  int _lastLen = -1;
  bool _closing = false;

  /// A conversa já começou? (só então "parado" significa que acabou)
  bool _started = false;

  @override
  void initState() {
    super.initState();
    s.addListener(_onChange);
    s.connect();
    _idle = Timer.periodic(const Duration(milliseconds: 500), (_) => _checkIdle());
  }

  void _onChange() {
    if (!mounted) return;
    final len = s.messages.fold<int>(0, (n, m) => n + m.text.length);
    if (len != _lastLen ||
        s.state == SessionState.speaking ||
        s.state == SessionState.thinking ||
        s.state == SessionState.connecting ||
        s.userLevel > 0.12) {
      _quietTicks = 0;
    }
    _lastLen = len;
    if (s.state != SessionState.idle) _started = true;
    if (s.state == SessionState.idle && _started && !_closing) {
      // A IA encerrou a conversa (encerrar_conversa) ou caiu.
      _close();
      return;
    }
    setState(() {});
  }

  void _checkIdle() {
    if (_closing) return;
    _quietTicks++;
    if (s.state == SessionState.error) {
      if (_quietTicks > 12) _close(); // mostra o erro por ~6 s
      return;
    }
    if (s.actions.any((a) => a.status == ActionStatus.running)) {
      _quietTicks = 0; // ferramenta rodando: espera
      return;
    }
    if (_quietTicks >= widget.idleSeconds * 2) _close();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _idle?.cancel();
    if (s.state != SessionState.idle) await s.disconnect();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _idle?.cancel();
    s.removeListener(_onChange);
    super.dispose();
  }

  String? _last(bool fromUser) {
    for (final m in s.messages.reversed) {
      if (m.isTool) continue;
      if (m.fromUser == fromUser) return m.text.trim();
    }
    return null;
  }

  String get _status => switch (s.state) {
        SessionState.connecting => 'Um segundo…',
        SessionState.listening => 'Pode falar',
        SessionState.thinking => 'Pensando…',
        SessionState.speaking => '',
        SessionState.error => s.error ?? 'Erro',
        SessionState.idle => '',
      };

  @override
  Widget build(BuildContext context) {
    final user = _last(true);
    final ai = _last(false);
    final tool = s.messages.isNotEmpty && s.messages.last.isTool ? s.messages.last.text : null;
    final level = s.state == SessionState.speaking ? s.agentLevel : s.userLevel;
    final text = Theme.of(context).textTheme;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, 1.1),
              radius: 1.3,
              colors: [Color(0xFF15183A), Color(0xFF05060D), Colors.black],
              stops: [0, 0.55, 1],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: Row(children: [
                    Expanded(
                      child: Text(widget.name.toUpperCase(),
                          style: text.labelMedium?.copyWith(color: Colors.white38, letterSpacing: 2.5)),
                    ),
                    IconButton(
                      tooltip: 'Fechar',
                      onPressed: _close,
                      icon: const Icon(Icons.close_rounded, color: Colors.white54),
                    ),
                  ]),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (user != null && user.isNotEmpty)
                          Text(user,
                              style: text.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w600, height: 1.25)),
                        if (ai != null && ai.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Text(ai, style: text.titleMedium?.copyWith(color: const Color(0xFFB9C6FF), height: 1.35)),
                        ],
                        if (tool != null) ...[
                          const SizedBox(height: 12),
                          Text(tool, style: text.bodySmall?.copyWith(color: Colors.white54)),
                        ],
                      ],
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => s.setMicEnabled(!s.micEnabled),
                  child: Opacity(
                    opacity: s.micEnabled ? 1 : 0.45,
                    child: AssistantLogo(state: s.state, level: level, size: 108),
                  ),
                ),
                SizedBox(
                  height: 40,
                  child: Text(
                    s.micEnabled ? _status : 'Microfone pausado — toque na logo',
                    textAlign: TextAlign.center,
                    style: text.bodySmall?.copyWith(
                        color: s.state == SessionState.error ? const Color(0xFFFF8A8A) : Colors.white60, letterSpacing: 0.3),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
