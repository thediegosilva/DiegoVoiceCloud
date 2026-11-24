import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:typed_data/typed_buffers.dart';

import '../../config/settings.dart';
import 'mesh_crypto.dart';

/// Tipos de mensagem entre os aparelhos.
enum MeshKind {
  /// Pedido para a IA do outro aparelho executar algo (ela responde com [reply]).
  task,

  /// Recado para o usuário: o aparelho de destino avisa / fala em voz alta.
  note,

  /// Resultado de uma [task].
  reply,

  /// Quem está online? / Estou online.
  ping,
  pong,
}

@immutable
class MeshMessage {
  const MeshMessage({
    required this.id,
    required this.from,
    required this.fromId,
    required this.to,
    required this.kind,
    required this.text,
    required this.ts,
    this.re,
    this.hops = 0,
    this.platform = '',
  });

  factory MeshMessage.fromJson(Map<String, dynamic> j) => MeshMessage(
        id: '${j['id']}',
        from: '${j['from']}',
        fromId: '${j['fid']}',
        to: '${j['to'] ?? '*'}',
        kind: MeshKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => MeshKind.note),
        text: '${j['text'] ?? ''}',
        ts: j['ts'] is int ? j['ts'] as int : 0,
        re: j['re'] as String?,
        hops: j['hops'] is int ? j['hops'] as int : 0,
        platform: '${j['pf'] ?? ''}',
      );

  final String id;
  final String from;
  final String fromId;

  /// Nome do aparelho de destino, ou "*" para todos.
  final String to;
  final MeshKind kind;
  final String text;
  final int ts;

  /// Id da mensagem que esta responde.
  final String? re;

  /// Quantas vezes já foi repassada (evita loops: máximo [MeshService.maxHops]).
  final int hops;
  final String platform;

  Map<String, dynamic> toJson() => {
        'id': id,
        'from': from,
        'fid': fromId,
        'to': to,
        'kind': kind.name,
        'text': text,
        'ts': ts,
        if (re != null) 're': re,
        'hops': hops,
        if (platform.isNotEmpty) 'pf': platform,
      };
}

/// Executa uma tarefa recebida de outro aparelho e devolve o resultado.
typedef MeshTaskHandler = Future<String> Function(MeshMessage task);

/// Rede privada entre os seus aparelhos ("Elo").
///
/// Todos os aparelhos com o mesmo código secreto entram no mesmo canal de um
/// servidor MQTT público (com TLS) e trocam mensagens cifradas com AES-GCM.
/// Funciona em redes diferentes (Wi-Fi de casa, 4G, trabalho) sem abrir portas.
class MeshService extends ChangeNotifier {
  MeshService(this.settings);

  final AppSettings settings;

  static const maxHops = 3;

  /// Mensagens mais velhas que isso são descartadas (contra reenvio de
  /// mensagens capturadas). Relógios dos aparelhos precisam estar certos.
  static const maxAge = Duration(minutes: 10);

  MqttServerClient? _client;
  MeshCrypto? _crypto;
  String? _cryptoFor;
  StreamSubscription? _sub;
  bool _wanted = false;
  int _brokerIdx = 0;
  Timer? _retry;

  bool connected = false;
  String status = 'Desligada';
  String? broker;

  /// Último "visto" de cada aparelho (nome → plataforma, horário).
  final Map<String, (String, DateTime)> peers = {};

  /// Mensagens recebidas para a interface/sessão (recados, respostas, tarefas).
  final _incoming = StreamController<MeshMessage>.broadcast();
  Stream<MeshMessage> get incoming => _incoming.stream;

  /// Quem executa tarefas recebidas (definido no main).
  MeshTaskHandler? onTask;

  final _seen = <String>{};
  final _seenOrder = <String>[];
  final _waitingReply = <String, Completer<MeshMessage>>{};
  final _pongs = <String, Completer<void>>{};

  String get myName => settings.deviceName;

  List<(String host, int port)> get _brokers {
    final out = <(String, int)>[];
    for (final b in settings.meshBrokers.split(',')) {
      final t = b.trim();
      if (t.isEmpty) continue;
      final i = t.lastIndexOf(':');
      out.add(i > 0 ? (t.substring(0, i), int.tryParse(t.substring(i + 1)) ?? 8883) : (t, 8883));
    }
    return out.isEmpty ? [('broker.emqx.io', 8883)] : out;
  }

  /// Liga/desliga conforme as configurações. Chame quando elas mudarem.
  Future<void> sync() async {
    final want = settings.meshEnabled && MeshCrypto.normalize(settings.meshCode).length >= MeshCrypto.minCodeLength;
    if (!want) {
      if (_wanted || _client != null) await stop();
      if (settings.meshEnabled) _setStatus('Defina um código secreto (mínimo ${MeshCrypto.minCodeLength} caracteres).');
      return;
    }
    final code = MeshCrypto.normalize(settings.meshCode);
    if (_wanted && _cryptoFor == code) return;
    await stop();
    _wanted = true;
    _setStatus('Preparando chaves…');
    try {
      _crypto = await MeshCrypto.derive(code);
      _cryptoFor = code;
    } catch (e) {
      _wanted = false;
      _setStatus('$e');
      return;
    }
    await _connect();
  }

  Future<void> _connect() async {
    if (!_wanted) return;
    final crypto = _crypto!;
    final (host, port) = _brokers[_brokerIdx % _brokers.length];
    _setStatus('Conectando em $host…');
    final rnd = Random.secure();
    final client = MqttServerClient.withPort(host, 'elo-${List.generate(10, (_) => rnd.nextInt(36).toRadixString(36)).join()}', port)
      ..secure = true
      ..keepAlivePeriod = 30
      ..connectTimeoutPeriod = 8000
      ..autoReconnect = true
      ..resubscribeOnAutoReconnect = true
      ..logging(on: false)
      ..setProtocolV311();
    client.onDisconnected = () {
      if (_client != client) return;
      connected = false;
      _setStatus('Desconectada');
    };
    client.onAutoReconnected = () {
      if (_client != client) return;
      connected = true;
      _setStatus('Conectada ($host)');
      _announce();
    };
    client.onConnected = () {};
    _client = client;
    try {
      final res = await client.connect();
      if (res?.state != MqttConnectionState.connected) throw Exception('recusado (${res?.returnCode})');
    } catch (e) {
      client.disconnect();
      if (_client != client || !_wanted) return;
      _client = null;
      _brokerIdx++;
      _setStatus('Falha em $host: ${e.toString().replaceFirst('Exception: ', '')}. Tentando outro…');
      _retry?.cancel();
      _retry = Timer(Duration(seconds: _brokerIdx % _brokers.length == 0 ? 15 : 1), _connect);
      return;
    }
    broker = host;
    client.subscribe(crypto.topic, MqttQos.atLeastOnce);
    _sub = client.updates?.listen((events) {
      for (final ev in events) {
        final pub = ev.payload;
        if (pub is! MqttPublishMessage) continue;
        _onData(Uint8List.fromList(pub.payload.message));
      }
    });
    connected = true;
    _setStatus('Conectada ($host)');
    _announce();
  }

  void _announce() => unawaited(_publish(MeshKind.pong, '*', ''));

  Future<void> stop() async {
    _wanted = false;
    _retry?.cancel();
    await _sub?.cancel();
    _sub = null;
    final c = _client;
    _client = null;
    c?.autoReconnect = false;
    try {
      c?.disconnect();
    } catch (_) {}
    connected = false;
    broker = null;
    _setStatus('Desligada');
  }

  void _setStatus(String s) {
    status = s;
    notifyListeners();
  }

  bool _isForMe(String to) {
    final t = normalizeSpeech(to);
    if (t == '*' || to == '*' || t.isEmpty) return true;
    final me = normalizeSpeech(myName);
    return t == me || t.contains(me) || me.contains(t);
  }

  Future<void> _onData(Uint8List data) async {
    final crypto = _crypto;
    if (crypto == null) return;
    final json = await crypto.open(data);
    if (json == null) return; // não é dos meus aparelhos
    final m = MeshMessage.fromJson(json);
    if (m.fromId == settings.installId) return; // eco da própria mensagem
    final age = DateTime.now().millisecondsSinceEpoch - m.ts;
    if (age.abs() > maxAge.inMilliseconds) return;
    if (!_seen.add(m.id)) return;
    _seenOrder.add(m.id);
    if (_seenOrder.length > 500) _seen.remove(_seenOrder.removeAt(0));

    peers[m.from] = (m.platform, DateTime.now());

    switch (m.kind) {
      case MeshKind.ping:
        if (_isForMe(m.to)) await _publish(MeshKind.pong, m.from, '', re: m.id);
        notifyListeners();
        return;
      case MeshKind.pong:
        if (m.re != null) _pongs[m.re]?.complete();
        notifyListeners();
        return;
      case MeshKind.reply:
        if (!_isForMe(m.to)) return;
        final w = m.re == null ? null : _waitingReply.remove(m.re);
        if (w != null && !w.isCompleted) {
          w.complete(m);
        } else {
          _incoming.add(m); // chegou depois que a ferramenta desistiu de esperar
        }
        return;
      case MeshKind.note:
        if (_isForMe(m.to)) _incoming.add(m);
        return;
      case MeshKind.task:
        if (!_isForMe(m.to)) return;
        _incoming.add(m);
        final handler = onTask;
        final String result;
        if (handler == null) {
          result = 'O $myName recebeu, mas não consegue executar tarefas agora (sem chave do Modelo de IA?).';
        } else {
          try {
            result = await handler(m);
          } catch (e) {
            await _publish(MeshKind.reply, m.from, 'Erro no $myName: $e', re: m.id);
            return;
          }
        }
        await _publish(MeshKind.reply, m.from, result, re: m.id);
        return;
    }
  }

  Future<String?> _publish(MeshKind kind, String to, String text, {String? re, int hops = 0}) async {
    final client = _client;
    final crypto = _crypto;
    if (client == null || crypto == null || !connected) return null;
    final rnd = Random.secure();
    final id = List.generate(12, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final msg = MeshMessage(
      id: id,
      from: myName,
      fromId: settings.installId,
      to: to,
      kind: kind,
      text: text,
      ts: DateTime.now().millisecondsSinceEpoch,
      re: re,
      hops: hops,
      platform: defaultTargetPlatform.name,
    );
    final sealed = await crypto.seal(msg.toJson());
    final buf = Uint8Buffer()..addAll(sealed);
    client.publishMessage(crypto.topic, MqttQos.atLeastOnce, buf);
    return id;
  }

  /// Pergunta quem está online e espera [wait] pelas respostas.
  Future<List<String>> discover({Duration wait = const Duration(seconds: 3)}) async {
    final since = DateTime.now();
    final id = await _publish(MeshKind.ping, '*', '');
    if (id == null) return [];
    final c = Completer<void>();
    _pongs[id] = c;
    await Future<void>.delayed(wait);
    _pongs.remove(id);
    return [
      for (final e in peers.entries)
        if (!e.value.$2.isBefore(since)) e.key
    ];
  }

  /// Manda um recado (o outro aparelho avisa o usuário).
  Future<bool> sendNote(String to, String text, {int hops = 0}) async =>
      await _publish(MeshKind.note, to, text, hops: hops) != null;

  /// Manda uma tarefa e espera a resposta por até [timeout].
  /// Devolve null se a resposta não chegou a tempo (ela ainda pode chegar
  /// depois, pelo [incoming]).
  Future<MeshMessage?> sendTask(String to, String text,
      {Duration timeout = const Duration(seconds: 40), int hops = 0}) async {
    if (hops >= maxHops) throw StateError('Repasse demais (máximo $maxHops aparelhos em cadeia).');
    final client = _client;
    if (client == null || !connected) throw StateError('A rede entre aparelhos não está conectada.');
    final c = Completer<MeshMessage>();
    final id = await _publish(MeshKind.task, to, text, hops: hops);
    if (id == null) throw StateError('Não consegui enviar.');
    _waitingReply[id] = c;
    try {
      return await c.future.timeout(timeout);
    } on TimeoutException {
      return null;
    } finally {
      // Mantém o registro por mais um tempo? Não: respostas tardias vão para
      // [incoming] e a sessão avisa o usuário.
      _waitingReply.remove(id);
    }
  }

  @override
  void dispose() {
    stop();
    _incoming.close();
    super.dispose();
  }
}
