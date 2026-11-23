import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'orb.dart';

/// Fundo estilo SaaS: base escura, aurora de luz difusa se movendo devagar,
/// grade fina que se dissolve nas bordas, holofote no topo e vinheta.
class AuroraBackdrop extends StatefulWidget {
  const AuroraBackdrop({super.key, required this.palette, required this.child, this.intensity = 1});

  final OrbPalette palette;
  final Widget child;

  /// 0–1: força da aurora (ex.: mais forte quando o Jarvis fala).
  final double intensity;

  @override
  State<AuroraBackdrop> createState() => _AuroraBackdropState();
}

class _AuroraBackdropState extends State<AuroraBackdrop> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _frame = _BackdropFrame();
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _frame.palette = widget.palette;
    _ticker = createTicker((elapsed) {
      final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
      _last = elapsed;
      _frame.time = elapsed.inMicroseconds / 1e6;
      final k = 1 - math.pow(0.02, dt).toDouble(); // ~1 s de transição
      _frame.palette = OrbPalette.lerp(_frame.palette, widget.palette, k);
      _frame.intensity += (widget.intensity.clamp(0.0, 1.0) - _frame.intensity) * k;
      _frame.tick();
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(child: CustomPaint(painter: _BackdropPainter(_frame))),
        widget.child,
      ],
    );
  }
}

class _BackdropFrame extends ChangeNotifier {
  double time = 0;
  double intensity = 0.6;
  OrbPalette palette = OrbPalette.male;

  void tick() => notifyListeners();
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter(this.f) : super(repaint: f);

  final _BackdropFrame f;

  static const _base = Color(0xFF05070D);
  static const _violet = Color(0xFF7C4DFF);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final w = size.width, h = size.height;
    final t = f.time;
    final p = f.palette;
    final glow = 0.75 + 0.25 * f.intensity;

    // 1) Base com leve degradê vertical
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(_base, p.deep, 0.35)!, _base, _base],
          stops: const [0, 0.55, 1],
        ).createShader(rect),
    );

    // 2) Aurora: manchas de luz grandes e suaves, em órbitas lentas
    final blobs = <(Color, double, double, double, double, double, double)>[
      // cor, centroX, centroY, raioX, raioY(da órbita), raio(da mancha), velocidade
      (p.primary, 0.20, 0.18, 0.18, 0.08, 0.75, 0.050),
      (p.accent, 0.85, 0.30, 0.12, 0.10, 0.60, -0.040),
      (Color.lerp(p.primary, _violet, 0.55)!, 0.55, 0.85, 0.20, 0.06, 0.80, 0.032),
    ];
    for (var i = 0; i < blobs.length; i++) {
      final (color, cx, cy, ox, oy, rad, speed) = blobs[i];
      final a = t * speed * 2 * math.pi + i * 2.1;
      final center = Offset(w * (cx + ox * math.cos(a)), h * (cy + oy * math.sin(a * 1.3)));
      final radius = math.max(w, h) * rad * (0.9 + 0.1 * math.sin(t * 0.3 + i));
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: 0.22 * glow),
              color.withValues(alpha: 0.07 * glow),
              color.withValues(alpha: 0),
            ],
            stops: const [0, 0.45, 1],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }

    // 3) Grade fina, mais visível no centro-alto e sumindo nas bordas
    final grid = Path();
    const step = 36.0;
    for (var x = (w / 2) % step; x < w; x += step) {
      grid
        ..moveTo(x, 0)
        ..lineTo(x, h);
    }
    for (var y = 0.0; y < h; y += step) {
      grid
        ..moveTo(0, y)
        ..lineTo(w, y);
    }
    canvas.saveLayer(rect, Paint());
    canvas.drawPath(
      grid,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = Colors.white.withValues(alpha: 0.055),
    );
    // máscara radial para a grade se dissolver
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = RadialGradient(
          center: const Alignment(0, -0.45),
          radius: 0.95,
          colors: [Colors.white, Colors.white.withValues(alpha: 0)],
        ).createShader(rect),
    );
    canvas.restore();

    // 4) Holofote suave no topo
    final spot = Rect.fromCenter(center: Offset(w / 2, -h * 0.05), width: w * 1.4, height: h * 0.7);
    canvas.drawOval(
      spot,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.white.withValues(alpha: 0.06), Colors.white.withValues(alpha: 0)],
        ).createShader(spot),
    );

    // 5) Vinheta nas bordas
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          radius: 1.1,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.55)],
          stops: const [0.6, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_BackdropPainter old) => old.f != f;
}

/// Painel de vidro (borda fina + fundo translúcido), padrão de UI SaaS.
class GlassPanel extends StatelessWidget {
  const GlassPanel({super.key, required this.child, this.padding = const EdgeInsets.all(12), this.radius = 24});

  final Widget child;
  final EdgeInsets padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withValues(alpha: 0.075), Colors.white.withValues(alpha: 0.03)],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: child,
    );
  }
}
