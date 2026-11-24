import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config/settings.dart';
import '../services/wake_service.dart';

/// Configurações da palavra de ativação ("acordar pela voz").
class WakeCard extends StatefulWidget {
  const WakeCard({super.key, required this.settings, required this.wake});

  final AppSettings settings;
  final WakeService wake;

  @override
  State<WakeCard> createState() => _WakeCardState();
}

class _WakeCardState extends State<WakeCard> with WidgetsBindingObserver {
  AppSettings get settings => widget.settings;
  WakeService get wake => widget.wake;

  bool _overlay = false;
  bool _battery = false;
  bool _testing = false;
  final List<String> _heard = [];
  StreamSubscription<String>? _heardSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    wake.addListener(_rebuild);
    _heardSub = wake.heard.listen((t) => setState(() {
          _heard.insert(0, t);
          if (_heard.length > 6) _heard.removeLast();
        }));
    _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Voltou das telas de permissão do sistema.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (!WakeService.supported) return;
    await wake.refresh();
    _overlay = await wake.canDrawOverlays();
    _battery = await wake.isIgnoringBattery();
    if (mounted) setState(() {});
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (_testing) wake.setTest(false);
    WidgetsBinding.instance.removeObserver(this);
    wake.removeListener(_rebuild);
    _heardSub?.cancel();
    _aliasCtl.dispose();
    super.dispose();
  }

  Future<void> _toggle(bool on) async {
    if (on) {
      final mic = await Permission.microphone.request();
      await Permission.notification.request();
      if (!mic.isGranted) {
        _snack('Sem permissão de microfone não dá para escutar o nome.');
        return;
      }
      if (!wake.modelReady) await wake.downloadModel();
    }
    settings.wakeWordEnabled = on;
    await wake.sync();
  }

  Future<void> _toggleTest() async {
    _testing = !_testing;
    _heard.clear();
    if (_testing && !wake.running) {
      // O teste usa o serviço; liga temporariamente se estiver desligado.
      settings.wakeWordEnabled = true;
      await wake.sync();
    }
    await wake.setTest(_testing);
    if (!_testing) await wake.sync(); // aplica as variações novas
    setState(() {});
  }

  void _useHeard(String t) {
    final aliases = settings.wakeAliases.split(',').map((a) => a.trim()).where((a) => a.isNotEmpty).toList();
    if (!aliases.contains(t)) aliases.add(t);
    settings.wakeAliases = aliases.join(', ');
    _aliasCtl.text = settings.wakeAliases;
    _snack('"$t" adicionado. Saia do teste para valer.');
  }

  late final _aliasCtl = TextEditingController(text: settings.wakeAliases);

  void _snack(String t) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(t)));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;

    if (Platform.isIOS) {
      return _box(context, [
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.record_voice_over_rounded),
          title: Text('Chamar pela Siri'),
        ),
        Text(
          'O iPhone não deixa nenhum app escutar com a tela bloqueada (só a Siri). Então use a Siri para acordar:\n\n'
          '• "E aí Siri, falar com Assistente" — abre direto no modo assistente.\n'
          '• Para usar o nome "${settings.assistantName}": no app Atalhos, crie um atalho com a ação '
          '"Chamar a IA" e dê a ele o nome "${settings.assistantName}". Aí é só dizer "E aí Siri, ${settings.assistantName}".',
          style: small,
        ),
      ]);
    }
    if (!WakeService.supported) {
      return _box(context, [
        Text('Acordar pela voz com a tela apagada funciona no Android (e pela Siri no iPhone). '
            'No PC, use o botão "Iniciar chamada".', style: small),
      ]);
    }

    final unknown = wake.unknownWords;
    return _box(context, [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: const Icon(Icons.hearing_rounded),
        title: Text('Acordar ao ouvir "${settings.assistantName}"'),
        subtitle: const Text('Funciona com a tela apagada. Escuta offline: nada sai do celular até você chamar. '
            'Gasta um pouco mais de bateria.'),
        value: settings.wakeWordEnabled,
        onChanged: _toggle,
      ),
      if (!wake.modelReady)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: wake.downloading
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Baixando o modelo de voz… ${(wake.progress * 100).round()}%', style: small),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: wake.progress > 0 ? wake.progress : null),
                ])
              : OutlinedButton.icon(
                  onPressed: wake.downloadModel,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Baixar modelo de voz em português (32 MB)'),
                ),
        ),
      if (wake.error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(wake.error!, style: small?.copyWith(color: scheme.error)),
        ),
      if (settings.wakeWordEnabled) ...[
        _permRow(
          ok: _overlay,
          title: 'Aparecer sobre outros apps',
          why: 'Para abrir na hora, por cima da tela de bloqueio. Sem isso, aparece uma notificação.',
          onFix: wake.requestOverlay,
        ),
        _permRow(
          ok: _battery,
          title: 'Sem economia de bateria',
          why: 'Para o Android não desligar a escuta depois de um tempo.',
          onFix: wake.requestBattery,
        ),
      ],
      const SizedBox(height: 8),
      TextField(
        controller: _aliasCtl,
        decoration: const InputDecoration(
          labelText: 'Como o reconhecedor ouve o nome (opcional)',
          hintText: 'ex.: léxico',
          helperText: 'Separe por vírgula. Use o teste abaixo para descobrir.',
        ),
        onChanged: (v) => settings.wakeAliases = v,
      ),
      if (unknown.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'O reconhecedor offline não conhece: ${unknown.map((u) => '"$u"').join(', ')}. '
            'Faça o teste, diga o nome e toque no que ele ouviu para usar.',
            style: small?.copyWith(color: const Color(0xFFFFC46B)),
          ),
        ),
      const SizedBox(height: 8),
      Row(children: [
        FilledButton.tonalIcon(
          onPressed: wake.modelReady ? _toggleTest : null,
          icon: Icon(_testing ? Icons.stop_rounded : Icons.mic_rounded),
          label: Text(_testing ? 'Parar teste' : 'Testar: diga o nome'),
        ),
      ]),
      if (_testing) ...[
        const SizedBox(height: 8),
        Text(_heard.isEmpty ? 'Fale o nome algumas vezes…' : 'Ouvi (toque para usar como variação):', style: small),
        Wrap(spacing: 6, children: [
          for (final h in _heard) ActionChip(label: Text(h), onPressed: () => _useHeard(h)),
        ]),
      ],
      const SizedBox(height: 12),
      Text('Fechar sozinho após ${settings.wakeIdleSeconds} s em silêncio', style: small),
      Slider(
        min: 5,
        max: 60,
        divisions: 55,
        value: settings.wakeIdleSeconds.toDouble().clamp(5, 60),
        label: '${settings.wakeIdleSeconds} s',
        onChanged: (v) => settings.wakeIdleSeconds = v.round(),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Sensibilidade alta'),
        subtitle: const Text('Use se ela não estiver acordando quando você chama. Pode acordar por engano com palavras parecidas.'),
        value: settings.wakeHighSensitivity,
        onChanged: (v) async {
          settings.wakeHighSensitivity = v;
          await wake.sync();
        },
      ),
      Text('Diego e Lexy foram testados com o reconhecedor offline. Outros nomes funcionam, mas use o teste acima '
          'para conferir como ele ouve.', style: small),
    ]);
  }

  Widget _permRow({required bool ok, required String title, required String why, required Future<void> Function() onFix}) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        leading: Icon(ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
            color: ok ? const Color(0xFF3DDC97) : const Color(0xFFFFC46B)),
        title: Text(title),
        subtitle: Text(why),
        trailing: ok ? null : TextButton(onPressed: onFix, child: const Text('Permitir')),
      );

  static Widget _box(BuildContext context, List<Widget> children) => Card(
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
        ),
      );
}
