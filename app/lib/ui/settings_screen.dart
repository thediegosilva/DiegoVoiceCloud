import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../config/prompts.dart';
import '../config/settings.dart';
import '../main.dart' show AppServices;
import '../services/pc_control.dart';
import '../services/terminal_service.dart';
import 'api_keys_card.dart';
import 'onboarding_screen.dart' show OnboardingScreen;
import 'mesh_card.dart';
import 'wake_card.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.services});

  final AppServices services;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppSettings get settings => widget.services.settings;

  @override
  void dispose() {
    // Aplica nome/variações/rede ao sair da tela.
    widget.services.syncBackground();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Configurações')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Chaves da API em primeiro: sem elas a IA não funciona.
            _section(context, 'Chaves da API'),
            ApiKeysCard(settings: settings),
            _section(context, 'Assistente'),
            Text('O nome muda junto com a voz: é como a IA se apresenta e a palavra que a acorda. '
                'Agora: ${settings.assistantName} (voz ${settings.voiceIsFemale ? 'feminina' : 'masculina'}).',
                style: Theme.of(context).textTheme.bodySmall),
            _NameField(
              label: 'Nome com voz masculina',
              value: settings.maleName,
              presets: AppSettings.presetMaleNames,
              icon: Icons.man_rounded,
              onChanged: (v) => settings.maleName = v,
            ),
            _NameField(
              label: 'Nome com voz feminina',
              value: settings.femaleName,
              presets: AppSettings.presetFemaleNames,
              icon: Icons.woman_rounded,
              onChanged: (v) => settings.femaleName = v,
            ),
            WakeCard(settings: settings, wake: widget.services.wake),
            _section(context, 'Rede entre meus aparelhos'),
            MeshCard(settings: settings, mesh: widget.services.mesh),
            _section(context, 'Geral'),
            _field('Como a IA te chama', settings.userName, (v) => settings.userName = v),
            _BirthField(settings: settings),
            _field('ID de memória (Mem0)', settings.userId, (v) => settings.userId = v,
                hint: 'opcional; por padrão vem do seu nome'),
            _section(context, 'Modo LiveKit (agente Python no PC)'),
            _field('URL do servidor de token', settings.tokenServerUrl, (v) => settings.tokenServerUrl = v,
                hint: 'http://IP-DO-PC:8787 ou URL do ngrok'),
            _field('Senha do servidor de token', settings.tokenServerPassword, (v) => settings.tokenServerPassword = v, secret: true),
            _section(context, 'Modelo de IA direto'),
            _field('Modelo', settings.geminiModel, (v) => settings.geminiModel = v),
            DropdownButtonFormField<String>(
              initialValue: _voices.contains(settings.geminiVoice) ? settings.geminiVoice : 'Kore',
              decoration: const InputDecoration(labelText: 'Voz'),
              items: [
                for (final v in _voices)
                  DropdownMenuItem(
                    value: v,
                    child: Text('$v · ${AppSettings.femaleVoices.contains(v) ? 'feminina (rosa)' : 'masculina (azul)'}'),
                  ),
              ],
              onChanged: (v) => settings.geminiVoice = v ?? 'Kore',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Modo meia-via (half-duplex)'),
              subtitle: const Text('Ligado (padrão): a IA não escuta enquanto fala, então nunca ouve a própria voz. '
                  'Desligue se quiser interrompê-la falando por cima.'),
              value: settings.halfDuplex,
              onChanged: (v) => settings.halfDuplex = v,
            ),
            _field('Chave do Mem0 (memória)', settings.mem0ApiKey, (v) => settings.mem0ApiKey = v, secret: true, hint: 'opcional'),
            _field('Token do Voice Monkey (casa)', settings.voiceMonkeyToken, (v) => settings.voiceMonkeyToken = v, secret: true, hint: 'opcional'),
            if (Platform.isLinux)
              _field('Modelos do agente de computador', settings.agentModels, (v) => settings.agentModels = v,
                  hint: 'separados por vírgula; o 1º é o preferido'),
            if (Platform.isLinux)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.mouse_rounded),
                title: const Text('Permitir controle de mouse e teclado'),
                subtitle: const Text('Com a tela compartilhada, a IA pode clicar, digitar e rolar de verdade. '
                    'Só ative se confiar no que vai pedir. Dá para desligar a qualquer momento na chamada.'),
                value: settings.allowComputerControl,
                onChanged: (v) => settings.allowComputerControl = v,
              ),
            if (TerminalService.supported) ...[
              const SizedBox(height: 12),
              const Text('Terminal', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              const Text('A IA pode rodar comandos no seu PC e ler o resultado. '
                  'Comandos perigosos (sudo, rm -r, desligar…) sempre pedem confirmação.',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              SegmentedButton<TerminalMode>(
                segments: const [
                  ButtonSegment(value: TerminalMode.off, label: Text('Desligado'), icon: Icon(Icons.block)),
                  ButtonSegment(value: TerminalMode.ask, label: Text('Perguntar'), icon: Icon(Icons.help_outline)),
                  ButtonSegment(value: TerminalMode.auto, label: Text('Automático'), icon: Icon(Icons.bolt)),
                ],
                selected: {settings.terminalMode},
                onSelectionChanged: (v) => settings.terminalMode = v.first,
              ),
              const SizedBox(height: 8),
            ],
            if (PcControl.supported)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Ferramentas de controle do PC'),
                subtitle: const Text('Arquivos, programas, volume, brilho, energia. Exclusões e desligar pedem confirmação.'),
                value: settings.pcToolsEnabled,
                onChanged: (v) => settings.pcToolsEnabled = v,
              ),
            const SizedBox(height: 8),
            TextFormField(
              initialValue: settings.systemPromptTemplate,
              minLines: 6,
              maxLines: 16,
              decoration: const InputDecoration(labelText: 'Personalidade (prompt) — {NOME} vira o nome da IA', border: OutlineInputBorder(), alignLabelWithHint: true),
              onChanged: (v) => settings.systemPrompt = v,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () {
                  settings.systemPrompt = kAgentInstruction;
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Prompt restaurado. Reabra a tela para ver.')));
                },
                child: const Text('Restaurar prompt padrão'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const _voices = ['Charon', 'Kore', 'Puck', 'Fenrir', 'Aoede', 'Leda', 'Orus', 'Zephyr'];

  Widget _section(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 4),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  Widget _field(String label, String value, ValueChanged<String> onChanged, {bool secret = false, String? hint}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextFormField(
          initialValue: value,
          obscureText: secret,
          decoration: InputDecoration(labelText: label, hintText: hint),
          onChanged: onChanged,
        ),
      );
}

/// Campo de nome com botões de nomes prontos.
class _NameField extends StatefulWidget {
  const _NameField({required this.label, required this.value, required this.presets, required this.icon, required this.onChanged});

  final String label;
  final String value;
  final List<String> presets;
  final IconData icon;
  final ValueChanged<String> onChanged;

  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  late final _c = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _c,
            decoration: InputDecoration(labelText: widget.label, prefixIcon: Icon(widget.icon)),
            onChanged: widget.onChanged,
          ),
          const SizedBox(height: 6),
          Wrap(spacing: 6, children: [
            for (final n in widget.presets)
              ChoiceChip(
                label: Text(n),
                selected: _c.text.trim().toLowerCase() == n.toLowerCase(),
                onSelected: (_) {
                  setState(() => _c.text = n);
                  widget.onChanged(n);
                },
              ),
          ]),
        ],
      ),
    );
  }
}

/// Data de nascimento (dd/mm/aaaa), salva quando fica válida.
class _BirthField extends StatelessWidget {
  const _BirthField({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final d = settings.birthDate;
    final initial = d == null
        ? ''
        : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextFormField(
        initialValue: initial,
        keyboardType: TextInputType.datetime,
        decoration: const InputDecoration(labelText: 'Data de nascimento', hintText: 'dd/mm/aaaa'),
        autovalidateMode: AutovalidateMode.onUserInteraction,
        validator: (v) => (v == null || v.isEmpty || OnboardingScreen.parseDate(v) != null) ? null : 'Use dd/mm/aaaa',
        onChanged: (v) {
          final p = OnboardingScreen.parseDate(v);
          if (p != null) settings.birthDate = p;
        },
      ),
    );
  }
}
