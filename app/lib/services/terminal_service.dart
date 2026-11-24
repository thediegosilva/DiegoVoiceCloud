import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Como a IA pode usar o terminal.
enum TerminalMode {
  /// Não pode rodar comandos.
  off,

  /// Pergunta ao usuário antes de cada comando.
  ask,

  /// Roda direto; comandos perigosos ainda pedem confirmação.
  auto,
}

/// Executa comandos de shell no PC (Linux/Windows) para a IA.
class TerminalService {
  TerminalService({required this.mode, required this.confirm});

  final TerminalMode Function() mode;
  final Future<bool> Function(String pergunta) confirm;

  static bool get supported => Platform.isLinux || Platform.isWindows;

  static const timeout = Duration(seconds: 60);
  static const maxOutput = 6000;

  late final String home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '.';

  /// Pasta atual (o `cd` da IA persiste entre comandos).
  late String cwd = home;

  /// Padrões que SEMPRE pedem confirmação, mesmo no modo automático.
  static final _dangerous = <RegExp>[
    RegExp(r'\bsudo\b'),
    RegExp(r'\bsu\s'),
    RegExp(r'\brm\s+(-[a-zA-Z]*[rRf]|--recursive|--force)'),
    RegExp(r'\b(mkfs|fdisk|parted|wipefs|shred)\b'),
    RegExp(r'\bdd\s+.*of='),
    RegExp(r'\b(shutdown|reboot|poweroff|halt)\b'),
    RegExp(r'\bsystemctl\s+(stop|disable|mask|poweroff|reboot)'),
    RegExp(r'\b(chmod|chown)\s+-R\b'),
    RegExp(r'>\s*/dev/(sd|nvme|hd)'),
    RegExp(r':\(\)\s*\{'),
    RegExp(r'(curl|wget)[^|]*\|\s*(ba|z)?sh\b'),
    RegExp(r'\bgit\s+(push\s+.*--force|reset\s+--hard|clean\s+-[a-zA-Z]*f)'),
    RegExp(r'\bkill(all)?\s+-9\s+-1\b'),
    RegExp(r'\b(apt|apt-get|dnf|pacman|snap)\s+(remove|purge|autoremove)\b'),
    RegExp(r'\bRemove-Item\b.*-Recurse', caseSensitive: false),
    RegExp(r'\b(format|diskpart)\b', caseSensitive: false),
  ];

  static bool isDangerous(String cmd) => _dangerous.any((r) => r.hasMatch(cmd));

  /// Roda [comando] e devolve saída + código de saída (texto para o modelo).
  Future<String> run(String comando) async {
    final cmd = comando.trim();
    if (cmd.isEmpty) return 'Comando vazio.';
    final m = mode();
    if (m == TerminalMode.off) {
      return 'O uso do terminal está desativado. O usuário pode liberar em Configurações → Terminal.';
    }
    final danger = isDangerous(cmd);
    if (m == TerminalMode.ask || danger) {
      final ok = await confirm('${danger ? '⚠️ Comando potencialmente perigoso.\n\n' : ''}'
          'A IA quer rodar no terminal (pasta $cwd):\n\n$cmd');
      if (!ok) return 'O usuário recusou este comando.';
    }

    // `cd` sozinho muda a pasta de trabalho persistente.
    final cdOnly = RegExp(r'^cd(\s+(.+))?$').firstMatch(cmd);
    if (cdOnly != null && !cmd.contains('&&') && !cmd.contains(';')) {
      var target = (cdOnly.group(2) ?? '~').trim().replaceAll(RegExp(r'''^['"]|['"]$'''), '');
      if (target == '~' || target.startsWith('~/')) target = home + target.substring(1);
      final dir = Directory(target.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(target) ? target : '$cwd/$target');
      if (!dir.existsSync()) return 'Pasta não encontrada: ${dir.path}';
      cwd = dir.resolveSymbolicLinksSync();
      return 'Pasta atual: $cwd';
    }

    final Process proc;
    try {
      proc = Platform.isWindows
          ? await Process.start('powershell', ['-NoProfile', '-Command', cmd], workingDirectory: cwd)
          : await Process.start('/bin/bash', ['-c', cmd], workingDirectory: cwd, environment: {'TERM': 'dumb', 'PAGER': 'cat', 'GIT_PAGER': 'cat'});
    } catch (e) {
      return 'Não consegui iniciar o comando: $e';
    }
    unawaited(proc.stdin.close()); // comandos interativos recebem EOF em vez de travar

    final out = StringBuffer();
    void add(String s) {
      if (out.length < maxOutput * 2) out.write(s);
    }

    final a = proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen(add);
    final b = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(add);
    var timedOut = false;
    final code = await proc.exitCode.timeout(timeout, onTimeout: () {
      timedOut = true;
      proc.kill(ProcessSignal.sigkill);
      return -1;
    });
    await Future.wait([a.asFuture<void>().catchError((_) {}), b.asFuture<void>().catchError((_) {})])
        .timeout(const Duration(seconds: 2), onTimeout: () => []);

    var text = out.toString().trimRight();
    if (text.length > maxOutput) {
      text = '${text.substring(0, maxOutput ~/ 2)}\n… (${text.length - maxOutput} caracteres omitidos) …\n${text.substring(text.length - maxOutput ~/ 2)}';
    }
    final status = timedOut
        ? 'Interrompido após ${timeout.inSeconds}s (comandos longos ou servidores: rode em segundo plano com nohup … &).'
        : 'Código de saída: $code';
    return '${text.isEmpty ? '(sem saída)' : text}\n[$status]';
  }
}
