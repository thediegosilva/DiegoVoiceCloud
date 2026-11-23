import 'package:livekit_client/livekit_client.dart' show VideoTrackRenderer;
import 'package:material_ui/material_ui.dart';

import '../services/livekit_session.dart';
import '../services/voice_session.dart';
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

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
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
            Text(_label,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: s.state == SessionState.error
                        ? scheme.error
                        : (widget.femaleVoice ? OrbPalette.female : OrbPalette.male).accent,
                    letterSpacing: 1.2)),
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
            const Divider(height: 24),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: s.messages.length,
                itemBuilder: (_, i) {
                  final m = s.messages[i];
                  if (m.isTool) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(m.text, style: TextStyle(fontSize: 12, color: scheme.outline, fontFamily: 'monospace')),
                    );
                  }
                  return Align(
                    alignment: m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      constraints: const BoxConstraints(maxWidth: 520),
                      decoration: BoxDecoration(
                        color: m.fromUser ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(m.text),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  IconButton.filledTonal(
                    tooltip: s.micEnabled ? 'Silenciar microfone' : 'Ativar microfone',
                    onPressed: () => s.setMicEnabled(!s.micEnabled),
                    icon: Icon(s.micEnabled ? Icons.mic : Icons.mic_off),
                  ),
                  if (s.supportsCamera)
                    IconButton.filledTonal(
                      tooltip: 'Câmera',
                      onPressed: () => s.setCameraEnabled(!s.cameraEnabled),
                      icon: Icon(s.cameraEnabled ? Icons.videocam : Icons.videocam_off),
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(hintText: 'Digite uma mensagem…', border: OutlineInputBorder(), isDense: true),
                    ),
                  ),
                  IconButton(onPressed: _send, icon: const Icon(Icons.send)),
                  IconButton.filled(
                    style: IconButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
                    tooltip: 'Encerrar',
                    onPressed: _hangUp,
                    icon: const Icon(Icons.call_end),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
