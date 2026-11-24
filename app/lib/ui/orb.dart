import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import '../services/voice_session.dart';

/// Paleta do orbe. [primary] = cor dominante, [accent] = brilho/realce,
/// [deep] = tom escuro das bordas.
@immutable
class OrbPalette {
  const OrbPalette(this.primary, this.accent, this.deep);

  final Color primary;
  final Color accent;
  final Color deep;

  /// Voz masculina: azul elétrico + ciano.
  static const male = OrbPalette(Color(0xFF2F7BFF), Color(0xFF3FE0FF), Color(0xFF0A2A6B));

  /// Voz feminina: rosa + magenta claro.
  static const female = OrbPalette(Color(0xFFFF4FA3), Color(0xFFFFA3DC), Color(0xFF6B0A45));

  static const error = OrbPalette(Color(0xFFFF4D4F), Color(0xFFFF9A8A), Color(0xFF5A0A0A));
  static const idle = OrbPalette(Color(0xFF4A5A70), Color(0xFF8FA3BF), Color(0xFF1A2230));

  static OrbPalette lerp(OrbPalette a, OrbPalette b, double t) => OrbPalette(
        Color.lerp(a.primary, b.primary, t)!,
        Color.lerp(a.accent, b.accent, t)!,
        Color.lerp(a.deep, b.deep, t)!,
      );
}

/// Orbe animado estilo assistente: núcleo de plasma que reage à voz, espectro
/// radial, anéis de HUD e partículas em órbita.
class AssistantOrb extends StatefulWidget {
  const AssistantOrb({
    super.key,
    required this.state,
    required this.level,
    this.female = false,
    this.size = 220,
  });

  final SessionState state;

  /// Volume atual (0–1) de quem está falando.
  final double level;

  /// true = paleta rosa (voz feminina); false = azul (voz masculina).
  final bool female;
  final double size;

  @override
  State<AssistantOrb> createState() => _AssistantOrbState();
}

class _AssistantOrbState extends State<AssistantOrb> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _frame = _OrbFrame();
  Duration _last = Duration.zero;

  OrbPalette get _target => switch (widget.state) {
        SessionState.error => OrbPalette.error,
        SessionState.idle => OrbPalette.idle,
        _ => widget.female ? OrbPalette.female : OrbPalette.male,
      };

  bool get _busy => widget.state == SessionState.thinking || widget.state == SessionState.connecting;

  @override
  void initState() {
    super.initState();
    _frame.palette = _target;
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _last = elapsed;
    final f = _frame;
    f.time = elapsed.inMicroseconds / 1e6;

    // Volume suavizado: sobe rápido, desce devagar.
    final target = widget.level.clamp(0.0, 1.0);
    final k = target > f.level ? 1 - math.pow(0.0005, dt) : 1 - math.pow(0.05, dt);
    f.level += (target - f.level) * k;

    // Velocidade dos anéis (integrada, para não "pular" ao mudar de estado).
    final wantSpin = _busy ? 2.6 : (widget.state == SessionState.speaking ? 0.9 : 0.45);
    f.spinSpeed += (wantSpin - f.spinSpeed) * (1 - math.pow(0.02, dt));
    f.spin += f.spinSpeed * dt;

    // Transição de cor suave (~0,4 s).
    f.palette = OrbPalette.lerp(f.palette, _target, 1 - math.pow(0.001, dt).toDouble());
    f.busy += ((_busy ? 1.0 : 0.0) - f.busy) * (1 - math.pow(0.01, dt));
    f.tick();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _OrbPainter(_frame),
      ),
    );
  }
}

/// Estado de cada quadro da animação (repinta sem reconstruir widgets).
class _OrbFrame extends ChangeNotifier {
  double time = 0;
  double level = 0;
  double spin = 0;
  double spinSpeed = 0.45;
  double busy = 0;
  OrbPalette palette = OrbPalette.male;

  void tick() => notifyListeners();
}

class _Particle {
  _Particle(math.Random r)
      : orbit = 0.50 + r.nextDouble() * 0.42,
        phase = r.nextDouble() * math.pi * 2,
        speed = (0.15 + r.nextDouble() * 0.45) * (r.nextBool() ? 1 : -1),
        size = 0.8 + r.nextDouble() * 1.8,
        twinkle = r.nextDouble() * math.pi * 2;

  final double orbit, phase, speed, size, twinkle;
}

class _OrbPainter extends CustomPainter {
  _OrbPainter(this.f) : super(repaint: f);

  final _OrbFrame f;

  static final List<_Particle> _particles = List.generate(26, (_) => _Particle(_rng));
  static final math.Random _rng = math.Random(7);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final t = f.time;
    final lv = f.level;
    final p = f.palette;
    final breathe = 0.5 + 0.5 * math.sin(t * 1.6);

    _aura(canvas, c, r, lv, breathe, p);
    _hudTicks(canvas, c, r, p);
    _hudArcs(canvas, c, r, p);
    _comet(canvas, c, r, p);
    _particlesLayer(canvas, c, r, t, lv, p);
    _spectrum(canvas, c, r, t, lv, p);
    _plasma(canvas, c, r, t, lv, breathe, p);
    _core(canvas, c, r, lv, breathe, p);
  }

  // Brilho difuso de fundo
  void _aura(Canvas canvas, Offset c, double r, double lv, double breathe, OrbPalette p) {
    final ar = r * (0.62 + 0.04 * breathe + 0.28 * lv);
    canvas.drawCircle(
      c,
      ar,
      Paint()
        ..shader = RadialGradient(
          colors: [
            p.primary.withValues(alpha: 0.42 + 0.25 * lv),
            p.deep.withValues(alpha: 0.22),
            p.deep.withValues(alpha: 0),
          ],
          stops: const [0, 0.5, 1],
        ).createShader(Rect.fromCircle(center: c, radius: ar)),
    );
  }

  // Régua circular com marcadores, girando devagar
  void _hudTicks(Canvas canvas, Offset c, double r, OrbPalette p) {
    const n = 72;
    final rot = f.spin * 0.12;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..color = p.accent.withValues(alpha: 0.28);
    for (var i = 0; i < n; i++) {
      final a = rot + i * 2 * math.pi / n;
      final major = i % 6 == 0;
      final r0 = r * (major ? 0.905 : 0.925);
      const r1Factor = 0.95;
      paint.strokeWidth = major ? 1.6 : 0.9;
      canvas.drawLine(
        c + Offset(math.cos(a), math.sin(a)) * r0,
        c + Offset(math.cos(a), math.sin(a)) * (r * r1Factor),
        paint,
      );
    }
  }

  // Arcos de HUD girando em sentidos opostos
  void _hudArcs(Canvas canvas, Offset c, double r, OrbPalette p) {
    final specs = <(double radius, double width, double speed, double sweep, int count, double alpha)>[
      (0.83, 2.2, 0.55, 0.95, 3, 0.75),
      (0.76, 1.3, -0.8, 0.45, 5, 0.45),
      (0.69, 3.0, 0.35, 0.22, 2, 0.35),
    ];
    for (final (radius, width, speed, sweep, count, alpha) in specs) {
      final rect = Rect.fromCircle(center: c, radius: r * radius);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..color = p.primary.withValues(alpha: alpha);
      for (var i = 0; i < count; i++) {
        final start = f.spin * speed + i * 2 * math.pi / count;
        canvas.drawArc(rect, start, sweep, false, paint);
      }
    }
  }

  // Cometa de luz: rastro com gradiente (bem visível ao "pensar")
  void _comet(Canvas canvas, Offset c, double r, OrbPalette p) {
    final rr = r * 0.875;
    final head = f.spin * 1.4;
    const tail = math.pi * 0.9;
    final rect = Rect.fromCircle(center: c, radius: rr);
    final alpha = 0.35 + 0.6 * f.busy;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(head - tail);
    canvas.translate(-c.dx, -c.dy);
    canvas.drawArc(
      rect,
      0,
      tail,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          center: Alignment.center,
          startAngle: 0,
          endAngle: tail,
          colors: [p.accent.withValues(alpha: 0), p.accent.withValues(alpha: alpha)],
        ).createShader(rect),
    );
    canvas.restore();
    // ponta brilhante
    final tip = c + Offset(math.cos(head), math.sin(head)) * rr;
    canvas.drawCircle(
      tip,
      3.2,
      Paint()
        ..color = Colors.white.withValues(alpha: alpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
  }

  // Partículas orbitando; afastam-se do centro com a voz
  void _particlesLayer(Canvas canvas, Offset c, double r, double t, double lv, OrbPalette p) {
    final paint = Paint()..blendMode = BlendMode.plus;
    for (final pt in _particles) {
      final a = pt.phase + t * pt.speed * (1 + f.busy * 1.5);
      final orbit = r * (pt.orbit + 0.06 * lv * math.sin(t * 3 + pt.phase));
      final tw = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(t * 2.2 + pt.twinkle));
      paint.color = Color.lerp(p.accent, Colors.white, 0.3)!.withValues(alpha: (0.25 + 0.5 * lv) * tw);
      canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * orbit, pt.size * (1 + lv * 0.6), paint);
    }
  }

  // Espectro radial (equalizador em volta do núcleo)
  void _spectrum(Canvas canvas, Offset c, double r, double t, double lv, OrbPalette p) {
    if (lv < 0.02) return;
    const n = 64;
    final base = r * 0.5;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.0
      ..blendMode = BlendMode.plus;
    for (var i = 0; i < n; i++) {
      final a = i * 2 * math.pi / n + f.spin * 0.2;
      // "Ruído" determinístico e fluido por barra
      final noise = 0.5 +
          0.30 * math.sin(t * 7.0 + i * 0.9) +
          0.20 * math.sin(t * 11.3 + i * 2.3) +
          0.15 * math.sin(t * 4.1 - i * 0.5);
      final len = r * 0.16 * lv * noise.clamp(0.08, 1.2);
      final dir = Offset(math.cos(a), math.sin(a));
      paint.color = Color.lerp(p.primary, p.accent, noise.clamp(0.0, 1.0))!.withValues(alpha: 0.35 + 0.5 * lv);
      canvas.drawLine(c + dir * base, c + dir * (base + len), paint);
    }
  }

  // Núcleo de plasma: contorno ondulado em 3 camadas sobrepostas
  void _plasma(Canvas canvas, Offset c, double r, double t, double lv, double breathe, OrbPalette p) {
    final r0 = r * (0.36 + 0.015 * breathe + 0.05 * lv);
    final amp = 0.03 + 0.015 * breathe + 0.20 * lv + 0.04 * f.busy;
    for (var layer = 0; layer < 3; layer++) {
      final k = layer * 2.1;
      final path = Path();
      const steps = 96;
      for (var i = 0; i <= steps; i++) {
        final a = i * 2 * math.pi / steps;
        final w = 0.50 * math.sin(3 * a + t * (1.3 + layer * 0.4) + k) +
            0.30 * math.sin(5 * a - t * (1.9 + layer * 0.3) + 2 * k) +
            0.20 * math.sin(7 * a + t * (2.7 - layer * 0.2) + 3 * k);
        final rr = r0 * (1 + amp * w) * (1 - layer * 0.07);
        final pt = c + Offset(math.cos(a), math.sin(a)) * rr;
        i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
      }
      path.close();
      final colorA = layer == 1 ? p.accent : p.primary;
      canvas.drawPath(
        path,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = RadialGradient(
            colors: [
              colorA.withValues(alpha: 0.55),
              colorA.withValues(alpha: 0.22),
              p.deep.withValues(alpha: 0.05),
            ],
            stops: const [0, 0.7, 1],
          ).createShader(Rect.fromCircle(center: c, radius: r0 * 1.3)),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..blendMode = BlendMode.plus
          ..color = Color.lerp(colorA, Colors.white, 0.35)!.withValues(alpha: 0.55 - layer * 0.12)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
      );
    }
  }

  // Centro incandescente
  void _core(Canvas canvas, Offset c, double r, double lv, double breathe, OrbPalette p) {
    final cr = r * (0.10 + 0.01 * breathe + 0.05 * lv);
    canvas.drawCircle(
      c,
      cr * 1.9,
      Paint()
        ..shader = ui.Gradient.radial(
          c,
          cr * 1.9,
          [
            Colors.white.withValues(alpha: 0.95),
            Color.lerp(p.accent, Colors.white, 0.4)!.withValues(alpha: 0.75),
            p.accent.withValues(alpha: 0),
          ],
          const [0, 0.42, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.f != f;
}
