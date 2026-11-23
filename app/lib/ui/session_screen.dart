import 'package:livekit_client/livekit_client.dart' show VideoTrackRenderer;
import 'package:material_ui/material_ui.dart';

import '../services/livekit_session.dart';
import '../services/voice_session.dart';
import 'backdrop.dart';
import 'orb.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.session, required this.title, this.femaleVoice = false});

  final VoiceSession session;
  final String title;

  /// Voz feminina → orbe rosa; masculina → azul.
  final bool femaleVoice;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();

  VoiceSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    s.addListener(_onChange);
    s.connect();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    s.removeListener(_onChange);
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String get _label => switch (s.state) {
        SessionState.idle => 'Desconectado',
        SessionState.connecting => 'Conectando…',
        SessionState.listening => 'Ouvindo',
        SessionState.thinking => 'Pensando…',
        SessionState.speaking => 'Falando',
        SessionState.error => 'Erro',
      };

  Future<void> _hangUp() async {
    await s.disconnect();
    if (mounted) Navigator.of(context).pop();
  }

  void _send() {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    s.sendText(t);
    _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final level = s.state == SessionState.speaking ? s.agentLevel : s.userLevel * 0.6;
    final lk = s is LiveKitSession ? s as LiveKitSession : null;
    final videoTrack = lk?.localVideoTrack;
    final palette = widget.femaleVoice ? OrbPalette.female : OrbPalette.male;
    final statusColor = s.state == SessionState.error ? scheme.error : palette.accent;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.3)),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: AuroraBackdrop(
        palette: s.state == SessionState.error ? OrbPalette.error : palette,
        intensity: s.state == SessionState.speaking ? 1 : 0.45,
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 4),
              Stack(
                alignment: Alignment.center,
                children: [
                  JarvisOrb(state: s.state, level: level, female: widget.femaleVoice, size: MediaQuery.sizeOf(context).height < 640 ? 150 : 210),
                  if (videoTrack != null && s.cameraEnabled)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(width: 96, height: 128, child: VideoTrackRenderer(videoTrack)),
                      ),
                    ),
                ],
              ),
              // Status em formato "pill"
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: statusColor.withValues(alpha: 0.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                        boxShadow: [BoxShadow(color: statusColor.withValues(alpha: 0.8), blurRadius: 8)],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(_label,
                        style: TextStyle(color: statusColor, fontWeight: FontWeight.w600, letterSpacing: 1.1, fontSize: 13)),
                  ],
                ),
              ),
              if (s.state == SessionState.error && s.error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Text(s.error!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
                      const SizedBox(height: 8),
                      FilledButton.tonal(onPressed: s.connect, child: const Text('Tentar de novo')),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Expanded(
                child: ShaderMask(
                  // mensagens somem suavemente no topo da lista
                  shaderCallback: (r) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.white, Colors.white],
                    stops: [0, 0.06, 1],
                  ).createShader(r),
                  blendMode: BlendMode.dstIn,
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    itemCount: s.messages.length,
                    itemBuilder: (_, i) => _bubble(s.messages[i], palette, scheme),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: GlassPanel(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  radius: 28,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: s.micEnabled ? 'Silenciar microfone' : 'Ativar microfone',
                        onPressed: () => s.setMicEnabled(!s.micEnabled),
                        icon: Icon(s.micEnabled ? Icons.mic_rounded : Icons.mic_off_rounded,
                            color: s.micEnabled ? palette.accent : scheme.outline),
                      ),
                      if (s.supportsCamera)
                        IconButton(
                          tooltip: 'Câmera',
                          onPressed: () => s.setCameraEnabled(!s.cameraEnabled),
                          icon: Icon(s.cameraEnabled ? Icons.videocam_rounded : Icons.videocam_off_rounded),
                        ),
                      Expanded(
                        child: TextField(
                          controller: _text,
                          onSubmitted: (_) => _send(),
                          decoration: const InputDecoration(
                            hintText: 'Digite uma mensagem…',
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 12),
                          ),
                        ),
                      ),
                      IconButton(onPressed: _send, icon: Icon(Icons.arrow_upward_rounded, color: palette.accent)),
                      const SizedBox(width: 2),
                      IconButton.filled(
                        style: IconButton.styleFrom(backgroundColor: const Color(0xFFE5484D), foregroundColor: Colors.white),
                        tooltip: 'Encerrar',
                        onPressed: _hangUp,
                        icon: const Icon(Icons.call_end_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bubble(ChatMessage m, OrbPalette palette, ColorScheme scheme) {
    if (m.isTool) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
          ),
          child: Text(m.text, style: TextStyle(fontSize: 12, color: scheme.outline, fontFamily: 'monospace')),
        ),
      );
    }
    final user = m.fromUser;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(user ? 18 : 6),
            bottomRight: Radius.circular(user ? 6 : 18),
          ),
          gradient: user
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [palette.primary, Color.lerp(palette.primary, palette.deep, 0.45)!],
                )
              : LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Colors.white.withValues(alpha: 0.085), Colors.white.withValues(alpha: 0.04)],
                ),
          border: user ? null : Border.all(color: Colors.white.withValues(alpha: 0.09)),
          boxShadow: user ? [BoxShadow(color: palette.primary.withValues(alpha: 0.25), blurRadius: 16, offset: const Offset(0, 4))] : null,
        ),
        child: Text(m.text, style: const TextStyle(color: Colors.white, height: 1.35, fontSize: 15)),
      ),
    );
  }
}
