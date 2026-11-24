import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mp_audio_stream/mp_audio_stream.dart';

/// Toca a voz da IA (PCM16 mono, 24 kHz).
///
/// - Android: player nativo "de chamada" que segue o fone Bluetooth / com fio
///   (e usa o microfone do fone) — veja CallAudio.kt.
/// - Demais: mp_audio_stream (miniaudio).
abstract class PcmPlayer {
  static const rate = 24000;

  /// Áudio juntado antes de começar a tocar (absorve oscilações da rede).
  static const prebufferMs = 250;

  factory PcmPlayer() => (!kIsWeb && Platform.isAndroid) ? _AndroidCallPlayer() : _MiniaudioPlayer();

  /// Player do Android (exposto para testes).
  @visibleForTesting
  factory PcmPlayer.android() => _AndroidCallPlayer();

  /// Rota atual: "bluetooth:NOME", "wired", "speaker" ou "" (desconhecida).
  ValueListenable<String> get route;

  /// Prepara o áudio da conversa (no Android, liga o fone Bluetooth).
  Future<void> start();

  void push(Uint8List pcm16);

  /// Descarta o que ainda não tocou (usuário interrompeu).
  void flush();

  Future<void> stop();
}

class _MiniaudioPlayer implements PcmPlayer {
  AudioStream? _s;

  @override
  final ValueNotifier<String> route = ValueNotifier('');

  AudioStream _new() => getAudioStream()
    ..init(
        sampleRate: PcmPlayer.rate,
        channels: 1,
        bufferMilliSec: 120000,
        waitingBufferMilliSec: PcmPlayer.prebufferMs,
        fadeOnExhaust: true)
    ..resume();

  @override
  Future<void> start() async => _s ??= _new();

  @override
  void push(Uint8List pcm16) {
    final s = _s;
    if (s == null) return;
    final n = pcm16.lengthInBytes ~/ 2;
    final view = ByteData.sublistView(pcm16);
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }
    s.push(out);
  }

  @override
  void flush() {
    _s?.uninit();
    _s = _new();
  }

  @override
  Future<void> stop() async {
    _s?.uninit();
    _s = null;
  }
}

class _AndroidCallPlayer implements PcmPlayer {
  _AndroidCallPlayer() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'route') route.value = '${call.arguments}';
      return null;
    });
  }

  static const _ch = MethodChannel('assistant/audio');

  @override
  final ValueNotifier<String> route = ValueNotifier('');

  final _pending = <Uint8List>[];
  int _pendingBytes = 0;
  Timer? _prime;
  int _until = 0; // ms em que o áudio já enviado termina de tocar
  bool _on = false;

  int get _now => DateTime.now().millisecondsSinceEpoch;
  static int _ms(int bytes) => bytes * 1000 ~/ (PcmPlayer.rate * 2);

  @override
  Future<void> start() async {
    _on = true;
    try {
      route.value = await _ch.invokeMethod<String>('start') ?? '';
    } on PlatformException catch (e) {
      debugPrint('[Audio] start: ${e.message}');
    }
  }

  @override
  void push(Uint8List pcm16) {
    if (!_on) return;
    if (_now >= _until) {
      // Parado: junta um pouco antes de tocar, para não picotar.
      _pending.add(pcm16);
      _pendingBytes += pcm16.lengthInBytes;
      _prime ??= Timer(const Duration(milliseconds: PcmPlayer.prebufferMs), _release);
      if (_ms(_pendingBytes) >= PcmPlayer.prebufferMs) _release();
      return;
    }
    _send(pcm16);
  }

  void _release() {
    _prime?.cancel();
    _prime = null;
    if (_pending.isEmpty) return;
    final all = BytesBuilder(copy: false);
    for (final p in _pending) {
      all.add(p);
    }
    _pending.clear();
    _pendingBytes = 0;
    _send(all.takeBytes());
  }

  void _send(Uint8List b) {
    _ch.invokeMethod('play', b);
    _until = math.max(_until, _now) + _ms(b.lengthInBytes);
  }

  @override
  void flush() {
    _prime?.cancel();
    _prime = null;
    _pending.clear();
    _pendingBytes = 0;
    _until = 0;
    _ch.invokeMethod('flush');
  }

  @override
  Future<void> stop() async {
    _on = false;
    flush();
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
    route.value = '';
  }
}
