import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../services/voice_session.dart';
import 'backdrop.dart';
import 'orb.dart';

/// Painel "o que o Jarvis está vendo e fazendo": tela ao vivo (com a marca do
/// último clique), câmera ao vivo e linha do tempo das ações.
class VisionPanel extends StatelessWidget {
  const VisionPanel({
    super.key,
    required this.session,
    required this.palette,
    this.scrollController,
  });

  final VoiceSession session;
  final OrbPalette palette;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final actions = s.actions.reversed.toList();
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      children: [
        if (s.supportsScreen) ...[
          _Header(
            icon: Icons.desktop_windows_rounded,
            title: 'Tela do PC',
            live: s.screenEnabled && s.lastScreenFrame != null,
            color: palette.accent,
            trailing: s.screenEnabled && s.controlEnabled
                ? const _Tag(text: 'CONTROLE', color: Color(0xFFFF5A5F))
                : null,
          ),
          _ScreenView(session: s, palette: palette),
          const SizedBox(height: 16),
        ],
        if (s.supportsCamera) ...[
          _Header(
            icon: Icons.videocam_rounded,
            title: 'Câmera',
            live: s.cameraEnabled && s.lastCameraFrame != null,
            color: palette.accent,
            trailing: s.cameraEnabled && s.supportsCameraSwitch
                ? IconButton(
                    tooltip: 'Trocar frontal/traseira',
                    visualDensity: VisualDensity.compact,
                    onPressed: s.switchCamera,
                    icon: const Icon(Icons.cameraswitch_rounded, size: 20),
                  )
                : null,
          ),
          _FrameBox(
            frame: s.cameraEnabled ? s.lastCameraFrame : null,
            aspect: 3 / 4,
            emptyText: s.cameraEnabled
                ? 'Abrindo a câmera…'
                : 'Câmera desligada',
            action: s.cameraEnabled
                ? null
                : ('Ligar câmera', () => s.setCameraEnabled(true)),
          ),
          const SizedBox(height: 16),
        ],
        if (s.taskRunning)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFFB020), foregroundColor: Colors.black),
              onPressed: s.cancelTask,
              icon: const Icon(Icons.stop_rounded),
              label: const Text('Parar tarefa'),
            ),
          ),
        _Header(
          icon: Icons.bolt_rounded,
          title: 'Ações',
          live: actions.any((a) => a.status == ActionStatus.running),
          color: palette.accent,
          trailing: Text(
            '${actions.length}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.outline,
              fontSize: 12,
            ),
          ),
        ),
        if (actions.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Nenhuma ação ainda. Peça algo como "abre o terminal e lista meus arquivos".',
              style: TextStyle(
                color: Theme.of(context).colorScheme.outline,
                fontSize: 13,
              ),
            ),
          ),
        for (final a in actions) _ActionTile(entry: a, palette: palette),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.icon,
    required this.title,
    required this.live,
    required this.color,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final bool live;
  final Color color;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 8),
          if (live) const _Tag(text: '● AO VIVO', color: Color(0xFF3DDC97)),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: color.withValues(alpha: 0.5)),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: color,
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.6,
      ),
    ),
  );
}

/// Tela ao vivo + marca do último clique (some após 4 s).
class _ScreenView extends StatelessWidget {
  const _ScreenView({required this.session, required this.palette});

  final VoiceSession session;
  final OrbPalette palette;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final recent =
        s.lastClickAt != null &&
        DateTime.now().difference(s.lastClickAt!) < const Duration(seconds: 4);
    return _FrameBox(
      frame: s.screenEnabled ? s.lastScreenFrame : null,
      aspect: s.screenAspect,
      emptyText: s.screenStarting
          ? 'Aprove o compartilhamento na janela do Ubuntu…'
          : s.screenEnabled
          ? 'Recebendo a tela…'
          : 'Compartilhamento desligado',
      action: s.screenEnabled || s.screenStarting
          ? null
          : ('Compartilhar tela', () => s.setScreenEnabled(true)),
      overlay: recent && s.lastClick != null
          ? LayoutBuilder(
              builder: (_, c) {
                final p = s.lastClick!;
                final x = p.dx.clamp(0, 1000) / 1000 * c.maxWidth;
                final y = p.dy.clamp(0, 1000) / 1000 * c.maxHeight;
                return Stack(
                  children: [
                    Positioned(
                      left: x - 14,
                      top: y - 14,
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFFFF5A5F),
                            width: 2.5,
                          ),
                          boxShadow: const [
                            BoxShadow(color: Color(0xAAFF5A5F), blurRadius: 12),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            )
          : null,
    );
  }
}

class _FrameBox extends StatelessWidget {
  const _FrameBox({
    required this.frame,
    required this.aspect,
    required this.emptyText,
    this.action,
    this.overlay,
  });

  final Uint8List? frame;
  final double aspect;
  final String emptyText;
  final (String, VoidCallback)? action;
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      padding: const EdgeInsets.all(4),
      radius: 16,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: AspectRatio(
            aspectRatio: aspect,
            child: frame == null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          emptyText,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                        if (action != null) ...[
                          const SizedBox(height: 10),
                          FilledButton.tonal(
                            onPressed: action!.$2,
                            child: Text(action!.$1),
                          ),
                        ],
                      ],
                    ),
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(
                        frame!,
                        gaplessPlayback: true,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                      ),
                      ?overlay,
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.entry, required this.palette});

  final ActionEntry entry;
  final OrbPalette palette;

  @override
  Widget build(BuildContext context) {
    final a = entry;
    final (icon, color) = switch (a.status) {
      ActionStatus.running => (null, palette.accent),
      ActionStatus.ok => (Icons.check_circle_rounded, const Color(0xFF3DDC97)),
      ActionStatus.failed => (Icons.error_rounded, const Color(0xFFFFB020)),
    };
    final t = a.started;
    final time =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      color: Colors.white.withValues(alpha: 0.85),
      height: 1.35,
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color:
              (a.status == ActionStatus.running ? palette.accent : Colors.white)
                  .withValues(alpha: 0.12),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            dense: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 10),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            leading: icon == null
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: color,
                    ),
                  )
                : Icon(icon, size: 20, color: color),
            title: Text(
              a.title,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13.5,
              ),
            ),
            subtitle: Text(
              [
                time,
                if (a.took != null)
                  '${(a.took!.inMilliseconds / 1000).toStringAsFixed(1)} s',
                if (a.detail.isNotEmpty) a.detail,
              ].join('  ·  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (a.detail.isNotEmpty)
                SelectableText(
                  a.detail,
                  style: mono.copyWith(color: palette.accent),
                ),
              if (a.result.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: SingleChildScrollView(
                    child: SelectableText(a.result, style: mono),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
