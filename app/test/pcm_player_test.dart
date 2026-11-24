import 'package:diego_voice_cloud/services/pcm_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ch = MethodChannel('assistant/audio');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, (c) async {
      calls.add(c);
      return c.method == 'start' ? 'bluetooth:Fone JBL' : null;
    });
  });

  // 100 ms de áudio a 24 kHz, 16 bits.
  Uint8List chunk() => Uint8List(24000 * 2 ~/ 10);

  test('liga a rota do fone, junta 250 ms antes de tocar, interrompe e desliga', () async {
    final p = PcmPlayer.android();
    await p.start();
    expect(calls.first.method, 'start');
    expect(p.route.value, 'bluetooth:Fone JBL');

    p.push(chunk());
    p.push(chunk());
    expect(calls.where((c) => c.method == 'play'), isEmpty, reason: 'ainda juntando o pré-buffer');
    p.push(chunk()); // 300 ms ≥ 250 ms → toca tudo junto
    await Future<void>.delayed(Duration.zero);
    final plays = calls.where((c) => c.method == 'play').toList();
    expect(plays, hasLength(1));
    expect((plays.single.arguments as Uint8List).lengthInBytes, chunk().lengthInBytes * 3);

    p.push(chunk()); // já tocando → vai direto
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((c) => c.method == 'play'), hasLength(2));

    p.flush();
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'flush');

    await p.stop();
    expect(calls.last.method, 'stop');
    expect(p.route.value, '');
  });

  test('fone conectado no meio da conversa atualiza a rota', () async {
    final p = PcmPlayer.android();
    await p.start();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'assistant/audio',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('route', 'wired')),
      (_) {},
    );
    expect(p.route.value, 'wired');
  });
}
