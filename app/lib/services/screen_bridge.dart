import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Compartilhamento de tela (e controle de mouse/teclado, se permitido) no
/// Linux, via `assets/desktop_bridge.py` (portais do GNOME/Wayland).
class ScreenBridge {
  ScreenBridge({required this.control});

  /// true = portal RemoteDesktop (vê + controla); false = só vê.
  final bool control;

  static bool get supported => Platform.isLinux;

  Process? _proc;
  final _frames = StreamController<Uint8List>.broadcast();
  final _pending = <int, Completer<String>>{};
  int _seq = 0;
  bool ready = false;

  /// Chamado quando a ponte encerra (erro, usuário negou, etc.).
  void Function(String? error)? onClosed;

  Stream<Uint8List> get frames => _frames.stream;

  /// Inicia e espera o "ready" (o usuário pode precisar aprovar no diálogo).
  Future<void> start() async {
    final script = await _extractScript();
    _proc = await Process.start('/usr/bin/python3', ['-I', script, '--mode', control ? 'control' : 'view', '--fps', '1']);
    final readyC = Completer<void>();
    String? lastError;

    _proc!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final Map<String, dynamic> m;
      try {
        m = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        return;
      }
      switch (m['type']) {
        case 'ready':
          ready = true;
          if (!readyC.isCompleted) readyC.complete();
        case 'frame':
          if (!_frames.isClosed) _frames.add(base64Decode(m['data'] as String));
        case 'result':
          final c = _pending.remove(m['id']);
          c?.complete(m['ok'] == true ? m['msg'] as String : 'Falhou: ${m['msg']}');
        case 'error':
          lastError = m['msg'] as String?;
          if (!readyC.isCompleted) readyC.completeError(Exception(lastError));
      }
    });
    _proc!.stderr.transform(utf8.decoder).listen((e) => debugPrint('[ScreenBridge] $e'));
    unawaited(_proc!.exitCode.then((_) {
      ready = false;
      for (final c in _pending.values) {
        c.complete('A ponte de tela foi encerrada.');
      }
      _pending.clear();
      if (!readyC.isCompleted) readyC.completeError(Exception(lastError ?? 'A ponte de tela encerrou.'));
      onClosed?.call(lastError);
    }));

    // Tempo para o usuário responder ao diálogo do sistema.
    await readyC.future.timeout(const Duration(minutes: 2));
  }

  static Future<String> _extractScript() async {
    final data = await rootBundle.loadString('assets/desktop_bridge.py');
    final dir = await Directory(p.join(Directory.systemTemp.path, 'jarvis-desktop')).create(recursive: true);
    final f = File(p.join(dir.path, 'desktop_bridge.py'));
    await f.writeAsString(data);
    return f.path;
  }

  /// Envia um comando de controle e espera o resultado.
  Future<String> command(Map<String, dynamic> cmd) async {
    final proc = _proc;
    if (proc == null || !ready) return 'O compartilhamento de tela não está ativo.';
    final id = ++_seq;
    final c = Completer<String>();
    _pending[id] = c;
    proc.stdin.writeln(jsonEncode({...cmd, 'id': id}));
    return c.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pending.remove(id);
      return 'Tempo esgotado executando o comando.';
    });
  }

  Future<void> stop() async {
    final proc = _proc;
    _proc = null;
    ready = false;
    if (proc == null) return;
    try {
      proc.stdin.writeln(jsonEncode({'cmd': 'stop'}));
      await proc.stdin.close();
    } catch (_) {}
    await proc.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
      proc.kill();
      return -1;
    });
  }

  Future<void> dispose() async {
    await stop();
    await _frames.close();
  }
}
