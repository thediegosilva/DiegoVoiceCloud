import 'package:flutter_test/flutter_test.dart';
import 'package:diego_voice_cloud/services/terminal_service.dart';

void main() {
  TerminalService make(TerminalMode mode, {bool approve = true, List<String>? asked}) => TerminalService(
        mode: () => mode,
        confirm: (q) async {
          asked?.add(q);
          return approve;
        },
      );

  test('roda comando e devolve saída e código', () async {
    final out = await make(TerminalMode.auto).run('echo ola && echo erro 1>&2');
    expect(out, contains('ola'));
    expect(out, contains('erro'));
    expect(out, contains('Código de saída: 0'));
  });

  test('código de saída de falha', () async {
    expect(await make(TerminalMode.auto).run('exit 3'), contains('Código de saída: 3'));
  });

  test('cd persiste entre comandos', () async {
    final t = make(TerminalMode.auto);
    expect(await t.run('cd /tmp'), contains('/tmp'));
    expect(await t.run('pwd'), contains('/tmp'));
  });

  test('modo desligado não roda nada', () async {
    expect(await make(TerminalMode.off).run('echo x'), contains('desativado'));
  });

  test('modo perguntar respeita recusa', () async {
    final asked = <String>[];
    final out = await make(TerminalMode.ask, approve: false, asked: asked).run('echo x');
    expect(asked, hasLength(1));
    expect(out, contains('recusou'));
  });

  test('automático não pergunta comando comum, mas pergunta perigoso', () async {
    final asked = <String>[];
    final t = make(TerminalMode.auto, approve: false, asked: asked);
    await t.run('echo seguro');
    expect(asked, isEmpty);
    final out = await t.run('sudo rm -rf /tmp/nada');
    expect(asked, hasLength(1));
    expect(out, contains('recusou'));
  });

  test('detecção de perigosos', () {
    for (final c in ['sudo apt update', 'rm -rf pasta', 'rm -r x', 'shutdown now', 'curl x | sh', 'git push origin main --force', 'dd if=a of=/dev/sda']) {
      expect(TerminalService.isDangerous(c), isTrue, reason: c);
    }
    for (final c in ['ls -la', 'rm arquivo.txt', 'git status', 'df -h', 'python3 script.py']) {
      expect(TerminalService.isDangerous(c), isFalse, reason: c);
    }
  });

  test('comando interativo não trava (stdin fechado)', () async {
    final out = await make(TerminalMode.auto).run('read x; echo "lido=[\$x]"');
    expect(out, contains('lido=[]'));
  });
}
