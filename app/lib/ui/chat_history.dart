import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../services/chat_store.dart';
import '../services/voice_session.dart';

String _when(DateTime d) {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Hoje, ${two(d.hour)}:${two(d.minute)}';
  if (diff == 1) return 'Ontem, ${two(d.hour)}:${two(d.minute)}';
  return '${two(d.day)}/${two(d.month)}/${d.year}';
}

/// Ações comuns (renomear, fixar, excluir) usadas na lateral e na conversa.
class ChatActions {
  static Future<void> rename(BuildContext context, ChatStore store, ChatSummary c) async {
    final ctl = TextEditingController(text: c.title);
    final t = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Renomear conversa'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Nome'),
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(d, ctl.text), child: const Text('Salvar')),
        ],
      ),
    );
    ctl.dispose();
    if (t != null && t.trim().isNotEmpty) await store.rename(c.id, t);
  }

  static Future<void> togglePin(BuildContext context, ChatStore store, ChatSummary c) async {
    final ok = await store.togglePin(c.id);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Dá para fixar até ${ChatStore.maxPinned} conversas. Desafixe uma antes.')));
    }
  }

  static Future<bool> delete(BuildContext context, ChatStore store, ChatSummary c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Excluir conversa?'),
        content: Text('"${c.title}" será apagada deste aparelho. Não dá para desfazer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE5484D)),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (ok == true) await store.delete(c.id);
    return ok == true;
  }
}

/// Lateral com o histórico de conversas (salvo só neste aparelho).
class ChatHistoryDrawer extends StatelessWidget {
  const ChatHistoryDrawer({super.key, required this.store, required this.onOpen, required this.onNew});

  final ChatStore store;
  final void Function(ChatSummary chat) onOpen;
  final VoidCallback onNew;

  Future<void> _deleteAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Excluir todas as conversas?'),
        content: Text('As ${store.chats.length} conversas serão apagadas deste aparelho, inclusive as fixadas. '
            'Não dá para desfazer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE5484D)),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Excluir tudo'),
          ),
        ],
      ),
    );
    if (ok == true) await store.deleteAll();
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: const Color(0xFF0B1020),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: store,
          builder: (context, _) {
            final chats = store.chats;
            final pinned = chats.where((c) => c.pinned).toList();
            final recent = chats.where((c) => !c.pinned).toList();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('Conversas', style: Theme.of(context).textTheme.titleLarge),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.pop(context);
                      onNew();
                    },
                    icon: const Icon(Icons.add_comment_rounded),
                    label: const Text('Nova conversa'),
                  ),
                ),
                Expanded(
                  child: chats.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('Suas conversas vão aparecer aqui.', textAlign: TextAlign.center),
                          ),
                        )
                      : ListView(
                          children: [
                            if (pinned.isNotEmpty) _label(context, 'Fixadas (${pinned.length}/${ChatStore.maxPinned})'),
                            for (final c in pinned) _tile(context, c),
                            if (recent.isNotEmpty) _label(context, 'Recentes'),
                            for (final c in recent) _tile(context, c),
                          ],
                        ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(children: [
                    const Icon(Icons.lock_rounded, size: 14, color: Colors.white54),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text('Salvas só neste aparelho.', style: TextStyle(fontSize: 12, color: Colors.white54)),
                    ),
                    if (chats.isNotEmpty)
                      TextButton.icon(
                        style: TextButton.styleFrom(foregroundColor: const Color(0xFFFF8A8A)),
                        onPressed: () => _deleteAll(context),
                        icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                        label: const Text('Excluir tudo'),
                      ),
                  ]),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _label(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(t, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Colors.white54)),
      );

  Widget _tile(BuildContext context, ChatSummary c) => ListTile(
        leading: Icon(c.pinned ? Icons.push_pin_rounded : Icons.chat_bubble_outline_rounded, size: 20),
        title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(_when(c.updated), style: const TextStyle(fontSize: 12)),
        onTap: () {
          Navigator.pop(context);
          onOpen(c);
        },
        trailing: PopupMenuButton<String>(
          tooltip: 'Opções',
          onSelected: (v) {
            switch (v) {
              case 'pin':
                ChatActions.togglePin(context, store, c);
              case 'rename':
                ChatActions.rename(context, store, c);
              case 'delete':
                ChatActions.delete(context, store, c);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'pin',
              child: ListTile(
                leading: Icon(c.pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded),
                title: Text(c.pinned ? 'Desafixar' : 'Fixar no topo'),
              ),
            ),
            const PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.edit_rounded), title: Text('Renomear'))),
            const PopupMenuItem(
              value: 'delete',
              child: ListTile(leading: Icon(Icons.delete_rounded, color: Color(0xFFFF8A8A)), title: Text('Excluir')),
            ),
          ],
        ),
      );
}

/// Lê uma conversa salva. "Continuar" fecha a tela devolvendo true.
class ChatViewScreen extends StatefulWidget {
  const ChatViewScreen({super.key, required this.store, required this.chatId});

  final ChatStore store;
  final String chatId;

  @override
  State<ChatViewScreen> createState() => _ChatViewScreenState();
}

class _ChatViewScreenState extends State<ChatViewScreen> {
  List<ChatMessage>? _msgs;

  @override
  void initState() {
    super.initState();
    widget.store.messages(widget.chatId).then((m) {
      if (mounted) setState(() => _msgs = m);
    });
  }

  void _copy(String t) {
    Clipboard.setData(ClipboardData(text: t));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copiado')));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final c = widget.store.byId(widget.chatId);
        if (c == null) return const Scaffold(body: Center(child: Text('Conversa excluída.')));
        final scheme = Theme.of(context).colorScheme;
        return Scaffold(
          appBar: AppBar(
            title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                tooltip: c.pinned ? 'Desafixar' : 'Fixar no topo',
                onPressed: () => ChatActions.togglePin(context, widget.store, c),
                icon: Icon(c.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined),
              ),
              IconButton(
                tooltip: 'Renomear',
                onPressed: () => ChatActions.rename(context, widget.store, c),
                icon: const Icon(Icons.edit_rounded),
              ),
              IconButton(
                tooltip: 'Excluir',
                onPressed: () async {
                  if (await ChatActions.delete(context, widget.store, c) && context.mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.delete_rounded),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.mic_rounded),
            label: const Text('Continuar conversa'),
          ),
          body: _msgs == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                  children: [
                    for (final m in _msgs!)
                      if (m.isTool)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Text(m.text, style: TextStyle(fontSize: 12, color: scheme.outline, fontFamily: 'monospace')),
                        )
                      else
                        Align(
                          alignment: m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
                          child: Column(
                            crossAxisAlignment: m.fromUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                            children: [
                              Container(
                                margin: const EdgeInsets.only(top: 6),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                constraints: const BoxConstraints(maxWidth: 520),
                                decoration: BoxDecoration(
                                  color: m.fromUser ? scheme.primary.withValues(alpha: 0.30) : Colors.white.withValues(alpha: 0.07),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: SelectableText(m.text, style: const TextStyle(height: 1.35, fontSize: 15)),
                              ),
                              InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () => _copy(m.text),
                                child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                    Icon(Icons.copy_rounded, size: 14, color: scheme.outline),
                                    const SizedBox(width: 4),
                                    Text('Copiar', style: TextStyle(fontSize: 11, color: scheme.outline)),
                                  ]),
                                ),
                              ),
                            ],
                          ),
                        ),
                  ],
                ),
        );
      },
    );
  }
}
