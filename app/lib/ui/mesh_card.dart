import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../config/settings.dart';
import '../services/mesh/mesh_crypto.dart';
import '../services/mesh/mesh_service.dart';

/// Configurações da rede privada entre os aparelhos do usuário.
class MeshCard extends StatefulWidget {
  const MeshCard({super.key, required this.settings, required this.mesh});

  final AppSettings settings;
  final MeshService mesh;

  @override
  State<MeshCard> createState() => _MeshCardState();
}

class _MeshCardState extends State<MeshCard> {
  AppSettings get settings => widget.settings;
  MeshService get mesh => widget.mesh;

  late final _code = TextEditingController(text: settings.meshCode);
  bool _show = false;
  bool _searching = false;
  List<String>? _found;

  @override
  void initState() {
    super.initState();
    mesh.addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    mesh.removeListener(_rebuild);
    _code.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    settings.meshCode = _code.text.trim();
    await mesh.sync();
  }

  Future<void> _generate() async {
    if (settings.meshCode.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Gerar um código novo?'),
          content: const Text('Os aparelhos com o código antigo param de conversar com este até você colocar o novo neles também.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Gerar')),
          ],
        ),
      );
      if (ok != true) return;
    }
    _code.text = MeshCrypto.generateCode();
    _show = true;
    await _apply();
  }

  Future<void> _search() async {
    setState(() => _searching = true);
    final found = await mesh.discover();
    if (!mounted) return;
    setState(() {
      _searching = false;
      _found = found;
    });
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final ok = mesh.connected;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.hub_rounded),
              title: const Text('Conectar meus aparelhos'),
              subtitle: const Text('As IAs do iPhone, Android e PC conversam entre si, mesmo em redes diferentes. '
                  'Tudo cifrado de ponta a ponta com o seu código.'),
              value: settings.meshEnabled,
              onChanged: (v) async {
                settings.meshEnabled = v;
                await mesh.sync();
              },
            ),
            if (settings.meshEnabled) ...[
              TextFormField(
                initialValue: settings.deviceName,
                decoration: const InputDecoration(
                  labelText: 'Nome deste aparelho',
                  helperText: 'É como a IA dos outros aparelhos chama este (ex.: PC, Android, iPhone).',
                ),
                onChanged: (v) => settings.deviceName = v,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _code,
                obscureText: !_show,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Código secreto',
                  helperText: 'O MESMO código em todos os seus aparelhos. Quem tiver o código controla as suas IAs — não compartilhe.',
                  helperMaxLines: 3,
                  suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      tooltip: _show ? 'Esconder' : 'Mostrar',
                      icon: Icon(_show ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                      onPressed: () => setState(() => _show = !_show),
                    ),
                    IconButton(
                      tooltip: 'Copiar',
                      icon: const Icon(Icons.copy_rounded),
                      onPressed: _code.text.isEmpty
                          ? null
                          : () {
                              Clipboard.setData(ClipboardData(text: _code.text));
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                  content: Text('Código copiado. Cole nos outros aparelhos e depois limpe a área de transferência.')));
                            },
                    ),
                  ]),
                ),
                onSubmitted: (_) => _apply(),
                onEditingComplete: _apply,
                onTapOutside: (_) {
                  if (_code.text.trim() != settings.meshCode) _apply();
                  FocusScope.of(context).unfocus();
                },
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                  onPressed: _generate,
                  icon: const Icon(Icons.key_rounded),
                  label: const Text('Gerar código novo'),
                ),
                OutlinedButton.icon(
                  onPressed: ok && !_searching ? _search : null,
                  icon: _searching
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.radar_rounded),
                  label: const Text('Procurar aparelhos'),
                ),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Icon(Icons.circle, size: 10, color: ok ? const Color(0xFF3DDC97) : const Color(0xFFFFC46B)),
                const SizedBox(width: 6),
                Expanded(child: Text(mesh.status, style: small)),
              ]),
              if (_found != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _found!.isEmpty ? 'Nenhum outro aparelho respondeu.' : 'Online: ${_found!.join(', ')}',
                    style: small,
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Falar recados em voz alta'),
                subtitle: const Text('Quando chegar um recado sem conversa aberta, a IA abre e fala (no Android, acende a tela).'),
                value: settings.meshSpeakNotes,
                onChanged: (v) => settings.meshSpeakNotes = v,
              ),
              Text(
                'Como funciona: as mensagens passam por um servidor público de recados (MQTT com TLS), mas cifradas '
                'com AES-256-GCM usando uma chave derivada do seu código. O servidor só vê bytes embaralhados num '
                'canal de nome aleatório. Pedidos perigosos (terminal, apagar, desligar) sempre pedem confirmação '
                'na tela do aparelho que vai executar.\n'
                'Para receber pedidos, o app precisa estar aberto no PC e no iPhone. No Android funciona em segundo plano.',
                style: small,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
