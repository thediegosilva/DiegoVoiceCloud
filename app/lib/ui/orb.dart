import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../services/voice_session.dart';

/// Orbe animado estilo JARVIS que reage ao estado e ao volume.
class JarvisOrb extends StatefulWidget {
  const JarvisOrb({super.key, required this.state, required this.level, this.size = 220});

  final SessionState state;
  final double level;
  final double size;

  @override
  State<JarvisOrb> createState() => _JarvisOrbState();
}

class _JarvisOrbState extends State<JarvisOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Color get _color => switch (widget.state) {
        SessionState.speaking => const Color(0xFF1FD5F9),
        SessionState.thinking || SessionState.connecting => const Color(0xFFFFB020),
        SessionState.error => const Color(0xFFFF4D4F),
        SessionState.idle => const Color(0xFF4A5A70),
        SessionState.listening => const Color(0xFF2F7BFF),
      };

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(
          size: Size.square(widget.size),
          painter: _OrbPainter(t: _c.value, level: widget.level, color: _color, busy: widget.state == SessionState.thinking || widget.state == SessionState.connecting),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.t, required this.level, required this.color, required this.busy});

  final double t;
  final double level;
  final Color color;
  final bool busy;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final pulse = 0.55 + level.clamp(0, 1) * 0.3;

    // brilho
    canvas.drawCircle(
      c,
      r * pulse,
      Paint()
        ..shader = RadialGradient(colors: [color.withValues(alpha: 0.9), color.withValues(alpha: 0.25), color.withValues(alpha: 0)], stops: const [0, 0.55, 1])
            .createShader(Rect.fromCircle(center: c, radius: r * pulse)),
    );

    // anéis
    for (var i = 0; i < 3; i++) {
      final rr = r * (0.62 + i * 0.12);
      final start = (t * 2 * math.pi * (i.isEven ? 1 : -1) * (busy ? 3 : 1)) + i;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: rr),
        start,
        math.pi * (0.9 + 0.3 * i),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5 - i * 0.6
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: 0.75 - i * 0.18),
      );
    }

    // núcleo
    canvas.drawCircle(c, r * 0.18 * (1 + level * 0.5), Paint()..color = Colors.white.withValues(alpha: 0.85));
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.t != t || old.level != level || old.color != color;
}
