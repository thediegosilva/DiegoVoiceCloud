import 'package:camera/camera.dart' show CameraPreview;
import 'package:livekit_client/livekit_client.dart' show VideoTrackRenderer;
import 'package:material_ui/material_ui.dart';

import '../services/gemini_live_session.dart';
import '../services/livekit_session.dart';
import '../services/voice_session.dart';
import 'backdrop.dart';
import 'orb.dart';
import 'vision_panel.dart';

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
        actions: [
          if (MediaQuery.sizeOf(context).width < 980)
            IconButton(
              tooltip: 'O que o Jarvis vê e faz',
              onPressed: () => _openPanel(context, palette),
              icon: Badge(
                isLabelVisible: s.actions.any((a) => a.status == ActionStatus.running) || s.screenEnabled || s.cameraEnabled,
                backgroundColor: const Color(0xFF3DDC97),
                smallSize: 8,
                child: const Icon(Icons.space_dashboard_rounded),
              ),
            ),
        ],
      ),
      body: AuroraBackdrop(
        palette: s.state == SessionState.error ? OrbPalette.error : palette,
        intensity: s.state == SessionState.speaking ? 1 : 0.45,
        child: SafeArea(
          child: _withPanel(context, palette, Column(
            children: [
              const SizedBox(height: 4),
              Stack(
                alignment: Alignment.center,
                children: [
                  JarvisOrb(state: s.state, level: level, female: widget.femaleVoice, size: MediaQuery.sizeOf(context).height < 640 ? 150 : 210),
                  if (s.cameraEnabled && _preview() != null)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Stack(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: palette.accent.withValues(alpha: 0.6), width: 1.2),
                              boxShadow: [BoxShadow(color: palette.primary.withValues(alpha: 0.35), blurRadius: 14)],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(13),
                              child: SizedBox(width: 96, height: 128, child: _preview()),
                            ),
                          ),
                          if (s.supportsCameraSwitch)
                            Positioned(
                              right: 4,
                              bottom: 4,
                              child: Material(
                                color: Colors.black.withValues(alpha: 0.55),
                                shape: const CircleBorder(),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: s.switchCamera,
                                  child: const Padding(
                                    padding: EdgeInsets.all(6),
                                    child: Icon(Icons.cameraswitch_rounded, size: 18, color: Colors.white),
                                  ),
                                ),
                              ),
                            ),
                        ],
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
              if (s.screenStarting || s.screenEnabled)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      _pill(
                        s.screenStarting ? 'Aprove o compartilhamento na janela do sistema…' : 'Vendo sua tela',
                        Icons.screen_share_rounded,
                        palette.accent,
                      ),
                      if (s.screenEnabled && s.controlEnabled)
                        _pill('Controle ativo · toque para desligar', Icons.mouse_rounded, const Color(0xFFFF5A5F),
                            onTap: () => s.setControlEnabled(false)),
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
                          tooltip: s.cameraEnabled ? 'Desligar câmera' : 'Mostrar a câmera para o Jarvis',
                          onPressed: () => s.setCameraEnabled(!s.cameraEnabled),
                          icon: Icon(s.cameraEnabled ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                              color: s.cameraEnabled ? palette.accent : null),
                        ),
                      if (s.supportsScreen)
                        IconButton(
                          tooltip: s.screenEnabled ? 'Parar de compartilhar a tela' : 'Mostrar minha tela para o Jarvis',
                          onPressed: s.screenStarting ? null : () => s.setScreenEnabled(!s.screenEnabled),
                          icon: Icon(s.screenEnabled ? Icons.stop_screen_share_rounded : Icons.screen_share_rounded,
                              color: s.screenEnabled ? palette.accent : null),
                        ),
                      if (s.supportsControl)
                        IconButton(
                          tooltip: s.controlEnabled ? 'Tirar o controle do mouse/teclado' : 'Permitir que o Jarvis use mouse e teclado',
                          onPressed: s.screenStarting ? null : () => _toggleControl(context),
                          icon: Icon(Icons.mouse_rounded, color: s.controlEnabled ? const Color(0xFFFF5A5F) : null),
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
        )),
      ),
    );
  }

  /// Tela larga (PC): painel fixo à direita. Estreita (celular): só a conversa.
  Widget _withPanel(BuildContext context, OrbPalette palette, Widget conversation) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < 980) return conversation;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: conversation),
          Container(
            width: 420,
            margin: const EdgeInsets.fromLTRB(0, 8, 12, 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: VisionPanel(session: s, palette: palette),
            ),
          ),
        ],
      );
    });
  }

  void _openPanel(BuildContext context, OrbPalette palette) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xF20A0E18),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (_, ctrl) => ListenableBuilder(
          listenable: s,
          builder: (_, _) => VisionPanel(session: s, palette: palette, scrollController: ctrl),
        ),
      ),
    );
  }

  Widget? _preview() {
    final ss = s;
    if (ss is LiveKitSession && ss.localVideoTrack != null) return VideoTrackRenderer(ss.localVideoTrack!);
    if (ss is GeminiLiveSession) {
      final c = ss.cameraController;
      if (c != null && c.value.isInitialized) {
        return FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: c.value.previewSize?.height ?? 96,
            height: c.value.previewSize?.width ?? 128,
            child: CameraPreview(c),
          ),
        );
      }
    }
    return null;
  }

  Widget _pill(String text, IconData icon, Color color, {VoidCallback? onTap}) {
    return Material(
      color: color.withValues(alpha: 0.12),
      shape: StadiumBorder(side: BorderSide(color: color.withValues(alpha: 0.45))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 6),
              Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleControl(BuildContext context) async {
    if (s.controlEnabled) {
      await s.setControlEnabled(false);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.mouse_rounded),
        title: const Text('Deixar o Jarvis usar mouse e teclado?'),
        content: const Text(
          'Com a tela compartilhada, ele poderá clicar, digitar e usar atalhos de verdade no seu PC.\n\n'
          'O Ubuntu vai pedir sua autorização. Para tirar o controle, toque no aviso vermelho "Controle ativo" '
          'ou no botão do mouse.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Permitir')),
        ],
      ),
    );
    if (ok == true) {
      await s.setControlEnabled(true);
      if (!s.screenEnabled && !s.screenStarting) await s.setScreenEnabled(true);
    }
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
