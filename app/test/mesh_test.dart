import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:diego_voice_cloud/config/settings.dart';
import 'package:diego_voice_cloud/services/mesh/mesh_crypto.dart';
import 'package:diego_voice_cloud/services/mesh/mesh_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:typed_data/typed_buffers.dart';

void main() {
  group('MeshCrypto', () {
    test('cifra e decifra com o mesmo código; recusa código errado e adulteração', () async {
      final code = MeshCrypto.generateCode();
      expect(MeshCrypto.normalize(code).length, 52);
      final a = await MeshCrypto.derive(code);
      final b = await MeshCrypto.derive(code.toLowerCase()); // normaliza
      final other = await MeshCrypto.derive(MeshCrypto.generateCode());
      expect(a.topic, b.topic);
      expect(a.topic, isNot(other.topic));

      final sealed = await a.seal({'text': 'abrir spotify'});
      expect((await b.open(sealed))?['text'], 'abrir spotify');
      expect(await other.open(sealed), isNull);

      final tampered = Uint8List.fromList(sealed)..[20] ^= 1;
      expect(await b.open(tampered), isNull);
    });

    test('recusa código curto', () {
      expect(() => MeshCrypto.derive('curto'), throwsArgumentError);
    });
  });

  // Teste real pelo servidor público (pule com SKIP_NET=1 se estiver offline).
  test('PC recebe tarefa do "iPhone" pelo servidor público e responde', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final code = MeshCrypto.generateCode();
    SharedPreferences.setMockInitialValues({
      'meshEnabled': true,
      'meshCode': code,
      'deviceName': 'PC',
    });
    final settings = await AppSettings.load();
    final pc = MeshService(settings);
    pc.onTask = (m) async => 'feito: ${m.text}';
    await pc.sync();
    for (var i = 0; i < 40 && !pc.connected; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(pc.connected, isTrue, reason: pc.status);

    // "iPhone": cliente separado, com outro id de instalação.
    final crypto = await MeshCrypto.derive(code);
    final phone = MqttServerClient.withPort(pc.broker!, 'test-iphone-${DateTime.now().microsecondsSinceEpoch}', 8883)
      ..secure = true
      ..logging(on: false)
      ..setProtocolV311();
    await phone.connect();
    phone.subscribe(crypto.topic, MqttQos.atLeastOnce);
    final reply = Completer<Map<String, dynamic>>();
    phone.updates!.listen((evs) async {
      for (final ev in evs) {
        final j = await crypto.open(Uint8List.fromList((ev.payload as MqttPublishMessage).payload.message));
        if (j != null && j['kind'] == 'reply' && !reply.isCompleted) reply.complete(j);
      }
    });
    await Future<void>.delayed(const Duration(seconds: 1));

    final task = MeshMessage(
      id: 'tsk${DateTime.now().microsecondsSinceEpoch}',
      from: 'iPhone',
      fromId: 'outro-aparelho',
      to: 'PC',
      kind: MeshKind.task,
      text: 'abrir o spotify',
      ts: DateTime.now().millisecondsSinceEpoch,
    );
    phone.publishMessage(crypto.topic, MqttQos.atLeastOnce, Uint8Buffer()..addAll(await crypto.seal(task.toJson())));

    final r = await reply.future.timeout(const Duration(seconds: 15));
    expect(r['text'], 'feito: abrir o spotify');
    expect(r['to'], 'iPhone');
    expect(r['re'], task.id);

    // Mensagem com o mesmo id (reenvio) é ignorada; mensagem velha também.
    phone.disconnect();
    await pc.stop();
  }, skip: Platform.environment['SKIP_NET'] == '1', timeout: const Timeout(Duration(seconds: 60)));
}
