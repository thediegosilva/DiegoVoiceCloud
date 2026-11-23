import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../config/prompts.dart';
import '../config/settings.dart';
import '../services/pc_control.dart';
import '../services/terminal_service.dart';
import 'api_keys_card.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Configurações')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _field('Seu nome / ID de memória', settings.userId, (v) => settings.userId = v),
            _section(context, 'Modo LiveKit (agente Python no PC)'),
            _field('URL do servidor de token', settings.tokenServerUrl, (v) => settings.tokenServerUrl = v,
                hint: 'http://IP-DO-PC:8787 ou URL do ngrok'),
            _field('Senha do servidor de token', settings.tokenServerPassword, (v) => settings.tokenServerPassword = v, secret: true),
            _section(context, 'Modo Gemini direto'),
            ApiKeysCard(settings: settings),
            _field('Modelo', settings.geminiModel, (v) => settings.geminiModel = v),
            DropdownButtonFormField<String>(
              initialValue: _voices.contains(settings.geminiVoice) ? settings.geminiVoice : 'Charon',
              decoration: const InputDecoration(labelText: 'Voz'),
              items: [
                for (final v in _voices)
                  DropdownMenuItem(
                    value: v,
                    child: Text('$v · ${AppSettings.femaleVoices.contains(v) ? 'feminina (rosa)' : 'masculina (azul)'}'),
                  ),
              ],
              onChanged: (v) => settings.geminiVoice = v ?? 'Charon',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Modo meia-via (half-duplex)'),
              subtitle: const Text('Não escuta enquanto o Jarvis fala. Ative se ele estiver ouvindo a própria voz (PC sem fone).'),
              value: settings.halfDuplex,
              onChanged: (v) => settings.halfDuplex = v,
            ),
            _field('Chave do Mem0 (memória)', settings.mem0ApiKey, (v) => settings.mem0ApiKey = v, secret: true, hint: 'opcional'),
            _field('Token do Voice Monkey (casa)', settings.voiceMonkeyToken, (v) => settings.voiceMonkeyToken = v, secret: true, hint: 'opcional'),
            if (Platform.isLinux)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.mouse_rounded),
                title: const Text('Permitir controle de mouse e teclado'),
                subtitle: const Text('Com a tela compartilhada, o Jarvis pode clicar, digitar e rolar de verdade. '
                    'Só ative se confiar no que vai pedir. Dá para desligar a qualquer momento na chamada.'),
                value: settings.allowComputerControl,
                onChanged: (v) => settings.allowComputerControl = v,
              ),
            if (TerminalService.supported) ...[
              const SizedBox(height: 12),
              const Text('Terminal', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              const Text('O Jarvis pode rodar comandos no seu PC e ler o resultado. '
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
              initialValue: settings.systemPrompt,
              minLines: 6,
              maxLines: 16,
              decoration: const InputDecoration(labelText: 'Personalidade (prompt)', border: OutlineInputBorder(), alignLabelWithHint: true),
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
