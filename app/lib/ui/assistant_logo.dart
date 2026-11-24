import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import '../services/voice_session.dart';

/// Logo do assistente (PNG estilo Siri) que pulsa com a voz.
///
/// - Ouvindo: "respira" devagar e reage ao volume do usuário.
/// - Pensando: gira mais rápido.
/// - Falando: cresce e brilha conforme o volume da IA.
class AssistantLogo extends StatefulWidget {
  const AssistantLogo({super.key, required this.state, required this.level, this.size = 120});

  final SessionState state;

  /// Volume 0–1 de quem está falando.
  final double level;
  final double size;

  @override
  State<AssistantLogo> createState() => _AssistantLogoState();
}

class _AssistantLogoState extends State<AssistantLogo> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _t = 0;
  double _level = 0;
  double _spin = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      final t = elapsed.inMicroseconds / 1e6;
      final dt = (t - _t).clamp(0.0, 0.1);
      _t = t;
      // Suaviza o volume (sobe rápido, desce devagar).
      final target = widget.level.clamp(0.0, 1.0);
      _level += (target - _level) * (target > _level ? 0.45 : 0.12);
      final speed = switch (widget.state) {
        SessionState.thinking || SessionState.connecting => 2.4,
        SessionState.speaking => 0.9 + _level * 2,
        _ => 0.35,
      };
      _spin += dt * speed;
      setState(() {});
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final speaking = widget.state == SessionState.speaking;
    final breathe = 0.5 + 0.5 * math.sin(_t * 2.2);
    final scale = 1.0 + (speaking ? _level * 0.32 : _level * 0.15 + breathe * 0.03);
    final glow = speaking ? 0.35 + _level * 0.65 : 0.25 + breathe * 0.15;
    final s = widget.size;
    return SizedBox(
      width: s * 1.6,
      height: s * 1.6,
      child: Center(
        child: Transform.scale(
          scale: scale,
          child: Container(
            width: s,
            height: s,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: const Color(0xFF5B8CFF).withValues(alpha: glow * 0.7), blurRadius: s * 0.35, spreadRadius: s * 0.02),
                BoxShadow(color: const Color(0xFFFF4FA3).withValues(alpha: glow * 0.35), blurRadius: s * 0.55, spreadRadius: -s * 0.05),
              ],
            ),
            child: Transform.rotate(
              angle: _spin,
              child: Image.asset('assets/images/assistant_logo.png', width: s, height: s, filterQuality: FilterQuality.medium),
            ),
          ),
        ),
      ),
    );
  }
}
