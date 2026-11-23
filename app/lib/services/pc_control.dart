import 'dart:io';

import 'package:path/path.dart' as p;

/// Porta de "Controle_PC/automacao_jarvis.py" para Dart, funcionando em
/// Linux e Windows (o original era só Windows).
///
/// Segurança: todos os caminhos são resolvidos e precisam ficar DENTRO da pasta
/// home do usuário. Ações destrutivas passam pelo callback [confirm].
class PcControl {
  PcControl({required this.confirm});

  /// Pergunta ao usuário na tela antes de ações destrutivas.
  final Future<bool> Function(String pergunta) confirm;

  static bool get supported => Platform.isLinux || Platform.isWindows;

  late final String home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '.';
  late String desktop = p.join(home, 'Desktop');
  late final String documents = p.join(home, 'Documents');
  late final String downloads = p.join(home, 'Downloads');

  static const _ignore = {'venv', '.venv', 'env', 'node_modules', '__pycache__', '.git', '.idea', '.vscode'};

  Future<void> init() async {
    // No Linux em português a pasta pode ser "Área de Trabalho".
    if (Platform.isLinux) {
      try {
        final r = await Process.run('xdg-user-dir', ['DESKTOP']);
        final d = (r.stdout as String).trim();
        if (r.exitCode == 0 && d.isNotEmpty && Directory(d).existsSync()) desktop = d;
      } catch (_) {}
    }
  }

  Map<String, String> get _aliases => {
        'area de trabalho': desktop,
        'área de trabalho': desktop,
        'desktop': desktop,
        'documentos': documents,
        'documents': documents,
        'downloads': downloads,
        'home': home,
      };

  String _resolve(String caminho) {
    var c = caminho.trim().replaceAll(RegExp(r'''^['"]|['"]$'''), '').replaceAll('\\', '/');
    final lower = c.toLowerCase();
    String out;
    final alias = _aliases.entries.where((e) => lower == e.key || lower.startsWith('${e.key}/')).firstOrNull;
    if (alias != null) {
      out = lower == alias.key ? alias.value : p.join(alias.value, c.substring(alias.key.length + 1));
    } else if (c.startsWith('~')) {
      out = p.join(home, c.substring(1).replaceFirst(RegExp(r'^/'), ''));
    } else if (p.isAbsolute(c)) {
      out = c;
    } else {
      out = p.join(desktop, c); // relativo → Área de Trabalho (igual ao original)
    }
    out = p.normalize(p.absolute(out));
    if (!p.isWithin(home, out) && !p.equals(home, out)) {
      throw Exception('Caminho fora da pasta do usuário não é permitido: $out');
    }
    return out;
  }

  Future<String> _guard(Future<String> Function() fn) async {
    if (!supported) return 'Controle do PC só funciona no app desktop (Linux/Windows).';
    try {
      return await fn();
    } catch (e) {
      return 'Erro: $e';
    }
  }

  Future<void> _openWithSystem(String target) async {
    if (Platform.isWindows) {
      await Process.start('cmd', ['/c', 'start', '', target], mode: ProcessStartMode.detached);
    } else {
      await Process.start('xdg-open', [target], mode: ProcessStartMode.detached);
    }
  }

  // ── Arquivos e pastas ──────────────────────────────────

  Future<String> criarPasta(String caminho) => _guard(() async {
        final path = _resolve(caminho);
        await Directory(path).create(recursive: true);
        return 'Pasta criada: $path';
      });

  Future<String> deletarItem(String caminho) => _guard(() async {
        final path = _resolve(caminho);
        if (p.equals(path, home) || _aliases.values.any((a) => p.equals(a, path))) {
          return 'Recusado: não vou apagar uma pasta base ($path).';
        }
        final type = FileSystemEntity.typeSync(path);
        if (type == FileSystemEntityType.notFound) return 'Caminho não encontrado: $path';
        if (!await confirm('Apagar definitivamente "$path"?')) return 'Usuário cancelou a exclusão.';
        await (type == FileSystemEntityType.directory ? Directory(path) : File(path)).delete(recursive: true);
        return 'Deletado: $path';
      });

  Future<String> limparDiretorio(String caminho) => _guard(() async {
        final path = _resolve(caminho);
        final dir = Directory(path);
        if (!dir.existsSync()) return 'Diretório não encontrado.';
        if (p.equals(path, home)) return 'Recusado: não vou limpar a pasta home inteira.';
        if (!await confirm('Apagar TODO o conteúdo de "$path"?')) return 'Usuário cancelou.';
        await for (final e in dir.list()) {
          await e.delete(recursive: true);
        }
        return 'Diretório limpo: $path';
      });

  Future<String> moverItem(String origem, String destino) => _guard(() async {
        final from = _resolve(origem);
        var to = _resolve(destino);
        if (Directory(to).existsSync()) to = p.join(to, p.basename(from));
        await _entity(from).rename(to);
        return 'Movido de $from para $to.';
      });

  Future<String> copiarItem(String origem, String destino) => _guard(() async {
        final from = _resolve(origem);
        var to = _resolve(destino);
        if (Directory(to).existsSync()) to = p.join(to, p.basename(from));
        if (FileSystemEntity.isDirectorySync(from)) {
          await _copyDir(Directory(from), Directory(to));
        } else {
          await File(from).copy(to);
        }
        return 'Copiado de $from para $to.';
      });

  Future<String> renomearItem(String caminho, String novoNome) => _guard(() async {
        final path = _resolve(caminho);
        final novo = _resolve(p.join(p.dirname(path), p.basename(novoNome)));
        await _entity(path).rename(novo);
        return 'Renomeado para ${p.basename(novo)}.';
      });

  Future<String> organizarPasta(String caminho) => _guard(() async {
        final path = _resolve(caminho);
        const ext = {
          'Imagens': ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp'],
          'Documentos': ['.pdf', '.doc', '.docx', '.txt', '.xlsx', '.pptx', '.csv', '.odt'],
          'Videos': ['.mp4', '.mkv', '.avi', '.mov'],
          'Musicas': ['.mp3', '.wav', '.flac', '.ogg'],
          'Compactados': ['.zip', '.rar', '.7z', '.tar', '.gz'],
          'Executaveis': ['.exe', '.msi', '.bat', '.sh', '.appimage', '.deb'],
        };
        var n = 0;
        await for (final e in Directory(path).list()) {
          if (e is! File) continue;
          final x = p.extension(e.path).toLowerCase();
          final pasta = ext.entries.where((k) => k.value.contains(x)).map((k) => k.key).firstOrNull ?? 'Outros';
          final destDir = Directory(p.join(path, pasta))..createSync();
          await e.rename(p.join(destDir.path, p.basename(e.path)));
          n++;
        }
        return 'Pasta organizada ($n arquivos movidos).';
      });

  Future<String> compactarPasta(String caminho) => _guard(() async {
        final path = _resolve(caminho);
        final zip = '$path.zip';
        final ProcessResult r;
        if (Platform.isWindows) {
          r = await Process.run('powershell', ['-NoProfile', '-Command', 'Compress-Archive', '-Path', '"$path\\*"', '-DestinationPath', '"$zip"', '-Force']);
        } else {
          r = await Process.run('zip', ['-r', '-q', zip, p.basename(path)], workingDirectory: p.dirname(path));
        }
        return r.exitCode == 0 ? 'Compactado em: $zip' : 'Falha ao compactar: ${r.stderr}';
      });

  Future<String> abrirPasta(String nome) => _guard(() async {
        final direct = _aliases[nome.toLowerCase()];
        if (direct != null && Directory(direct).existsSync()) {
          await _openWithSystem(direct);
          return 'Abrindo $nome.';
        }
        for (final base in {desktop, documents, downloads}) {
          await for (final d in _walk(Directory(base))) {
            if (d is Directory && p.basename(d.path).toLowerCase() == nome.toLowerCase()) {
              await _openWithSystem(d.path);
              return 'Pasta aberta: ${d.path}';
            }
          }
        }
        return "Pasta '$nome' não encontrada.";
      });

  Future<String> buscarEAbrirArquivo(String nome) => _guard(() async {
        for (final base in {desktop, documents, downloads}) {
          await for (final f in _walk(Directory(base))) {
            if (f is File && p.basename(f.path).toLowerCase().contains(nome.toLowerCase())) {
              await _openWithSystem(f.path);
              return 'Arquivo aberto: ${f.path}';
            }
          }
        }
        return "Arquivo '$nome' não encontrado.";
      });

  // ── Programas ──────────────────────────────────────────

  static const _linuxApps = {
    'calculadora': ['gnome-calculator'],
    'bloco de notas': ['gnome-text-editor'],
    'editor de texto': ['gnome-text-editor'],
    'terminal': ['gnome-terminal'],
    'explorador de arquivos': ['nautilus'],
    'arquivos': ['nautilus'],
    'configuracoes': ['gnome-control-center'],
    'configurações': ['gnome-control-center'],
    'vscode': ['code'],
    'chrome': ['google-chrome'],
    'navegador': ['xdg-open', 'https://www.google.com'],
    'spotify': ['spotify'],
  };

  static const _windowsApps = {
    'calculadora': 'calc.exe',
    'bloco de notas': 'notepad.exe',
    'paint': 'mspaint.exe',
    'cmd': 'cmd.exe',
    'terminal': 'wt.exe',
    'explorador de arquivos': 'explorer.exe',
    'navegador': 'msedge',
    'word': 'winword',
    'excel': 'excel',
    'powerpoint': 'powerpnt',
    'configuracoes': 'ms-settings:',
    'configurações': 'ms-settings:',
    'vscode': 'code',
    'chrome': 'chrome',
    'spotify': 'spotify:',
  };

  Future<String> abrirAplicativo(String nome) => _guard(() async {
        final key = nome.toLowerCase().trim();
        if (Platform.isWindows) {
          final target = _windowsApps[key] ?? nome;
          // sem shell=True: o nome vai como argumento, não como linha de comando
          await Process.start('cmd', ['/c', 'start', '', target], mode: ProcessStartMode.detached);
        } else {
          final cmd = _linuxApps[key] ?? [key];
          await Process.start(cmd.first, cmd.sublist(1), mode: ProcessStartMode.detached);
        }
        return 'Abrindo $nome.';
      });

  Future<String> fecharPrograma(String nome) => _guard(() async {
        final ProcessResult r;
        if (Platform.isWindows) {
          final exe = nome.toLowerCase().endsWith('.exe') ? nome : '$nome.exe';
          r = await Process.run('taskkill', ['/f', '/im', exe]);
        } else {
          r = await Process.run('pkill', ['-i', '-x', nome]);
        }
        return r.exitCode == 0 ? "Programa '$nome' fechado." : "Não encontrei o processo '$nome'.";
      });

  // ── Sistema ────────────────────────────────────────────

  Future<String> controleVolume(int nivel) => _guard(() async {
        final n = nivel.clamp(0, 100);
        final ProcessResult r;
        if (Platform.isWindows) {
          r = await Process.run('powershell', ['-NoProfile', '-Command', _winVolumeScript(n)]);
        } else {
          r = await Process.run('pactl', ['set-sink-volume', '@DEFAULT_SINK@', '$n%']);
        }
        return r.exitCode == 0 ? 'Volume ajustado para $n%.' : 'Erro no volume: ${r.stderr}';
      });

  Future<String> controleBrilho(int nivel) => _guard(() async {
        final n = nivel.clamp(1, 100);
        final ProcessResult r;
        if (Platform.isWindows) {
          r = await Process.run('powershell', [
            '-NoProfile',
            '-Command',
            '(Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightnessMethods).WmiSetBrightness(1,$n)'
          ]);
        } else {
          r = await Process.run('brightnessctl', ['set', '$n%']);
        }
        return r.exitCode == 0
            ? 'Brilho ajustado para $n%.'
            : 'Não consegui ajustar o brilho (${Platform.isLinux ? 'instale o brightnessctl' : 'monitor externo não suporta'}).';
      });

  Future<String> energiaPc(String acao) => _guard(() async {
        final a = acao.toLowerCase().trim();
        if (a == 'bloquear') {
          if (Platform.isWindows) {
            await Process.run('rundll32.exe', ['user32.dll,LockWorkStation']);
          } else {
            await Process.run('loginctl', ['lock-session']);
          }
          return 'Computador bloqueado.';
        }
        if (a != 'desligar' && a != 'reiniciar') return 'Ação inválida. Use desligar, reiniciar ou bloquear.';
        if (!await confirm('Confirmar: $a o computador?')) return 'Usuário cancelou.';
        if (Platform.isWindows) {
          await Process.run('shutdown', [a == 'desligar' ? '/s' : '/r', '/t', '5']);
        } else {
          await Process.run('systemctl', [a == 'desligar' ? 'poweroff' : 'reboot']);
        }
        return a == 'desligar' ? 'Desligando o computador.' : 'Reiniciando o computador.';
      });

  // ── Helpers ────────────────────────────────────────────

  FileSystemEntity _entity(String path) =>
      FileSystemEntity.isDirectorySync(path) ? Directory(path) : File(path);

  Stream<FileSystemEntity> _walk(Directory dir) async* {
    if (!dir.existsSync()) return;
    try {
      await for (final e in dir.list(followLinks: false)) {
        final name = p.basename(e.path);
        if (e is Directory) {
          if (_ignore.contains(name) || name.startsWith('.')) continue;
          yield e;
          yield* _walk(e);
        } else {
          yield e;
        }
      }
    } on FileSystemException {
      // sem permissão: ignora
    }
  }

  Future<void> _copyDir(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final e in from.list()) {
      final target = p.join(to.path, p.basename(e.path));
      if (e is Directory) {
        await _copyDir(e, Directory(target));
      } else if (e is File) {
        await e.copy(target);
      }
    }
  }

  /// Ajusta o volume mestre no Windows via COM (IAudioEndpointVolume), sem
  /// dependências extras.
  static String _winVolumeScript(int n) => r'''
Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume { int f(); int g(); int h(); int i(); int SetMasterVolumeLevelScalar(float fLevel, System.Guid pguidEventContext); }
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice { int Activate(ref System.Guid id, int clsCtx, int activationParams, out IAudioEndpointVolume aev); }
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator { int f(); int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint); }
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject { }
public class JarvisAudio {
  public static void SetVolume(float v) {
    var enumerator = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
    IMMDevice dev; enumerator.GetDefaultAudioEndpoint(0, 1, out dev);
    var iid = typeof(IAudioEndpointVolume).GUID; IAudioEndpointVolume epv;
    dev.Activate(ref iid, 23, 0, out epv);
    epv.SetMasterVolumeLevelScalar(v, System.Guid.Empty);
  }
}
"@
''' '[JarvisAudio]::SetVolume(${n / 100})';
}
