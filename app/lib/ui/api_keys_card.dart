import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../config/settings.dart';

/// Gerenciador das chaves da API do Gemini (até [AppSettings.maxApiKeys]).
/// Toque numa chave para torná-la a ativa.
class ApiKeysCard extends StatelessWidget {
  const ApiKeysCard({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final keys = settings.geminiKeys;
    final activeId = settings.activeKeyId;
    final full = keys.length >= AppSettings.maxApiKeys;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
            child: Row(
              children: [
                Icon(Icons.vpn_key_rounded, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                const Expanded(child: Text('Chaves da API do Gemini', style: TextStyle(fontWeight: FontWeight.w600))),
                Text('${keys.length}/${AppSettings.maxApiKeys}', style: TextStyle(color: scheme.outline, fontSize: 12)),
                IconButton(
                  tooltip: full ? 'Limite de ${AppSettings.maxApiKeys} chaves' : 'Adicionar chave',
                  onPressed: full ? null : () => _edit(context),
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
          ),
          if (keys.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                'Nenhuma chave ainda. Crie uma grátis em aistudio.google.com/apikey e toque em + para adicionar.',
                style: TextStyle(color: scheme.outline, fontSize: 13),
              ),
            ),
          for (final k in keys)
            ListTile(
              onTap: () => settings.activeKeyId = k.id,
              leading: Icon(
                k.id == activeId ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: k.id == activeId ? scheme.primary : scheme.outline,
              ),
              title: Text(k.label),
              subtitle: Text(k.masked, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (k.id == activeId)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text('em uso', style: TextStyle(color: scheme.primary, fontSize: 11)),
                    ),
                  PopupMenuButton<String>(
                    onSelected: (v) => v == 'edit' ? _edit(context, entry: k) : _remove(context, k),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Editar')),
                      PopupMenuItem(value: 'remove', child: Text('Remover')),
                    ],
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, {ApiKeyEntry? entry}) async {
    final label = TextEditingController(text: entry?.label ?? '');
    final key = TextEditingController(text: entry?.key ?? '');
    final formKey = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(entry == null ? 'Nova chave' : 'Editar chave'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: label,
                decoration: const InputDecoration(labelText: 'Apelido', hintText: 'Ex.: Pessoal, Trabalho, Reserva'),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: key,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Chave da API',
                  hintText: 'AIza…',
                  suffixIcon: IconButton(
                    tooltip: 'Colar',
                    icon: const Icon(Icons.content_paste),
                    onPressed: () async {
                      final d = await Clipboard.getData(Clipboard.kTextPlain);
                      if (d?.text != null) key.text = d!.text!.trim();
                    },
                  ),
                ),
                validator: (v) => (v == null || v.trim().length < 20) ? 'Chave inválida' : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) Navigator.pop(ctx, true);
            },
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (entry == null) {
      await settings.addKey(label.text, key.text);
    } else {
      await settings.updateKey(entry.id, label: label.text, key: key.text);
    }
  }

  Future<void> _remove(BuildContext context, ApiKeyEntry k) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remover chave?'),
        content: Text('"${k.label}" (${k.masked}) será apagada deste aparelho.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remover')),
        ],
      ),
    );
    if (ok == true) await settings.removeKey(k.id);
  }
}

/// Seletor rápido da chave ativa (usado na tela inicial).
class ApiKeyPicker extends StatelessWidget {
  const ApiKeyPicker({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final keys = settings.geminiKeys;
    final active = settings.activeKey;
    if (keys.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<String>(
      tooltip: 'Trocar chave da API',
      onSelected: (id) => settings.activeKeyId = id,
      itemBuilder: (_) => [
        for (final k in keys)
          CheckedPopupMenuItem(value: k.id, checked: k.id == active?.id, child: Text('${k.label}  ·  ${k.masked}')),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.vpn_key_rounded, size: 16),
            const SizedBox(width: 8),
            Text(active?.label ?? '—', style: const TextStyle(fontWeight: FontWeight.w600)),
            if (keys.length > 1) const Icon(Icons.expand_more, size: 18),
          ],
        ),
      ),
    );
  }
}
