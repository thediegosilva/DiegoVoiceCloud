import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

/// Câmera do celular para o modo Gemini direto: tira uma foto JPEG a cada
/// [interval] e entrega em [frames]. Permite alternar frontal/traseira.
class CameraFeed {
  CameraFeed({this.interval = const Duration(milliseconds: 1200)});

  final Duration interval;

  static bool get supported => Platform.isAndroid || Platform.isIOS;

  CameraController? controller;
  CameraLensDirection lens = CameraLensDirection.back;
  final _frames = StreamController<Uint8List>.broadcast();
  Timer? _timer;
  bool _busy = false;
  List<CameraDescription> _cams = const [];

  Stream<Uint8List> get frames => _frames.stream;
  bool get canSwitch => _cams.map((c) => c.lensDirection).toSet().length > 1;

  Future<void> start() async {
    _cams = await availableCameras();
    if (_cams.isEmpty) throw Exception('Nenhuma câmera encontrada.');
    await _open(lens);
    _timer = Timer.periodic(interval, (_) => _capture());
  }

  Future<void> _open(CameraLensDirection dir) async {
    final cam = _cams.firstWhere((c) => c.lensDirection == dir, orElse: () => _cams.first);
    lens = cam.lensDirection;
    final old = controller;
    controller = null;
    await old?.dispose();
    final c = CameraController(cam, ResolutionPreset.medium, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
    await c.initialize();
    try {
      await c.setFlashMode(FlashMode.off);
    } catch (_) {}
    controller = c;
  }

  /// Alterna entre câmera frontal e traseira.
  Future<void> switchLens() async {
    final next = lens == CameraLensDirection.back ? CameraLensDirection.front : CameraLensDirection.back;
    _busy = true;
    try {
      await _open(next);
    } finally {
      _busy = false;
    }
  }

  Future<void> _capture() async {
    final c = controller;
    if (_busy || c == null || !c.value.isInitialized || c.value.isTakingPicture) return;
    _busy = true;
    try {
      final file = await c.takePicture();
      final bytes = await file.readAsBytes();
      unawaited(File(file.path).delete().catchError((_) => File(file.path)));
      if (!_frames.isClosed) _frames.add(bytes);
    } catch (e) {
      debugPrint('[Camera] $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final c = controller;
    controller = null;
    await c?.dispose();
  }

  Future<void> dispose() async {
    await stop();
    await _frames.close();
  }
}
