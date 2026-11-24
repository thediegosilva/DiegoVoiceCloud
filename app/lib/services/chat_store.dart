import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'voice_session.dart';

/// Resumo de uma conversa salva (o que aparece na lista lateral).
class ChatSummary {
  ChatSummary({
    required this.id,
    required this.title,
    required this.created,
    required this.updated,
    this.pinnedAt,
    this.customTitle = false,
  });

  factory ChatSummary.fromJson(Map<String, dynamic> j) => ChatSummary(
        id: j['id'] as String,
        title: j['title'] as String? ?? 'Conversa',
        created: DateTime.fromMillisecondsSinceEpoch(j['created'] as int? ?? 0),
        updated: DateTime.fromMillisecondsSinceEpoch(j['updated'] as int? ?? 0),
        pinnedAt: j['pinnedAt'] == null ? null : DateTime.fromMillisecondsSinceEpoch(j['pinnedAt'] as int),
        customTitle: j['customTitle'] == true,
      );

  final String id;
  String title;
  final DateTime created;
  DateTime updated;

  /// Fixada no topo (null = não fixada).
  DateTime? pinnedAt;

  /// O usuário renomeou (não troca mais o título sozinho).
  bool customTitle;

  bool get pinned => pinnedAt != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'created': created.millisecondsSinceEpoch,
        'updated': updated.millisecondsSinceEpoch,
        if (pinnedAt != null) 'pinnedAt': pinnedAt!.millisecondsSinceEpoch,
        if (customTitle) 'customTitle': true,
      };
}

/// Histórico de conversas guardado SÓ neste aparelho (arquivos JSON na pasta
/// privada do app). Nada vai para servidor nenhum.
///
/// Fotos não são guardadas: no histórico ficam só como "📸 Foto".
class ChatStore extends ChangeNotifier {
  ChatStore({Directory? dir}) : _dirOverride = dir;

  static const maxPinned = 5;

  final Directory? _dirOverride;
  Directory? _dir;
  final List<ChatSummary> _chats = [];
  bool loaded = false;

  /// Uma escrita por vez no disco.
  Future<void> _last = Future.value();
  Future<T> _locked<T>(Future<T> Function() f) {
    final next = _last.then((_) => f());
    _last = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// Fixadas primeiro (na ordem em que foram fixadas), depois as mais recentes.
  List<ChatSummary> get chats {
    final pinned = _chats.where((c) => c.pinned).toList()..sort((a, b) => a.pinnedAt!.compareTo(b.pinnedAt!));
    final rest = _chats.where((c) => !c.pinned).toList()..sort((a, b) => b.updated.compareTo(a.updated));
    return [...pinned, ...rest];
  }

  int get pinnedCount => _chats.where((c) => c.pinned).length;

  Future<Directory> _folder() async {
    if (_dir != null) return _dir!;
    final base = _dirOverride ?? Directory(p.join((await getApplicationSupportDirectory()).path, 'conversas'));
    await base.create(recursive: true);
    return _dir = base;
  }

  File _index(Directory d) => File(p.join(d.path, 'indice.json'));
  File _file(Directory d, String id) => File(p.join(d.path, '$id.json'));

  Future<void> load() async {
    final d = await _folder();
    _chats.clear();
    final idx = _index(d);
    if (await idx.exists()) {
      try {
        for (final e in jsonDecode(await idx.readAsString()) as List) {
          _chats.add(ChatSummary.fromJson(e as Map<String, dynamic>));
        }
      } catch (e) {
        debugPrint('[Histórico] índice ilegível: $e');
      }
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> _saveIndex() async {
    final d = await _folder();
    final tmp = File('${_index(d).path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final c in _chats) c.toJson()]));
    await tmp.rename(_index(d).path); // troca atômica: nunca fica pela metade
  }

  ChatSummary? byId(String id) {
    for (final c in _chats) {
      if (c.id == id) return c;
    }
    return null;
  }

  static String newId() {
    final r = Random.secure();
    return '${DateTime.now().millisecondsSinceEpoch}_${r.nextInt(1 << 30).toRadixString(36)}';
  }

  /// Título automático: começo da primeira fala do usuário.
  static String autoTitle(List<ChatMessage> msgs, DateTime when) {
    for (final fromUser in [true, false]) {
      for (final m in msgs) {
        final t = m.text.trim();
        if (m.isTool || m.fromUser != fromUser || t.isEmpty || t.startsWith('📸') || t.startsWith('🖼️')) continue;
        final one = t.replaceAll(RegExp(r'\s+'), ' ');
        return one.length > 42 ? '${one.substring(0, 42).trimRight()}…' : one;
      }
    }
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Conversa de ${two(when.day)}/${two(when.month)} ${two(when.hour)}:${two(when.minute)}';
  }

  static bool hasContent(List<ChatMessage> msgs) => msgs.any((m) => !m.isTool && m.text.trim().isNotEmpty);

  /// Salva (cria ou atualiza) a conversa [id] com estas mensagens.
  Future<void> save(String id, List<ChatMessage> msgs) => _locked(() => _save(id, msgs));

  Future<void> _save(String id, List<ChatMessage> msgs) async {
    if (!hasContent(msgs)) return;
    final d = await _folder();
    final now = DateTime.now();
    var c = byId(id);
    if (c == null) {
      c = ChatSummary(id: id, title: autoTitle(msgs, now), created: now, updated: now);
      _chats.add(c);
    } else {
      c.updated = now;
      if (!c.customTitle) c.title = autoTitle(msgs, c.created);
    }
    final data = [
      for (final m in msgs)
        if (m.text.trim().isNotEmpty) {'u': m.fromUser, 't': m.text, if (m.isTool) 'tool': true}
    ];
    final f = _file(d, id);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode({'messages': data}));
    await tmp.rename(f.path);
    await _saveIndex();
    notifyListeners();
  }

  Future<List<ChatMessage>> messages(String id) async {
    final f = _file(await _folder(), id);
    if (!await f.exists()) return [];
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      var i = 0;
      return [
        for (final m in j['messages'] as List)
          ChatMessage(
            id: 'h${i++}',
            fromUser: (m as Map)['u'] == true,
            text: m['t'] as String? ?? '',
            isTool: m['tool'] == true,
          )
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> rename(String id, String title) => _locked(() => _rename(id, title));

  Future<void> _rename(String id, String title) async {
    final c = byId(id);
    final t = title.trim();
    if (c == null || t.isEmpty) return;
    c
      ..title = t.length > 60 ? t.substring(0, 60) : t
      ..customTitle = true;
    await _saveIndex();
    notifyListeners();
  }

  /// Fixa/desafixa. Devolve false se já houver [maxPinned] fixadas.
  Future<bool> togglePin(String id) => _locked(() => _togglePin(id));

  Future<bool> _togglePin(String id) async {
    final c = byId(id);
    if (c == null) return false;
    if (!c.pinned && pinnedCount >= maxPinned) return false;
    c.pinnedAt = c.pinned ? null : DateTime.now();
    await _saveIndex();
    notifyListeners();
    return true;
  }

  Future<void> delete(String id) => _locked(() => _delete(id));

  Future<void> _delete(String id) async {
    _chats.removeWhere((c) => c.id == id);
    final f = _file(await _folder(), id);
    if (await f.exists()) await f.delete();
    await _saveIndex();
    notifyListeners();
  }

  Future<void> deleteAll() => _locked(() => _deleteAll());

  Future<void> _deleteAll() async {
    final d = await _folder();
    for (final c in List.of(_chats)) {
      final f = _file(d, c.id);
      if (await f.exists()) await f.delete();
    }
    _chats.clear();
    await _saveIndex();
    notifyListeners();
  }
}

/// Grava a conversa de uma sessão enquanto ela acontece (com uma pequena
/// espera para não escrever no disco a cada palavra).
class ChatRecorder {
  ChatRecorder(this.store, this.session, this.chatId) {
    session.addListener(_onChange);
  }

  final ChatStore store;
  final VoiceSession session;
  final String chatId;
  Timer? _debounce;
  int _lastLen = -1;

  void _onChange() {
    final len = session.messages.fold<int>(session.messages.length, (n, m) => n + m.text.length);
    if (len == _lastLen) return;
    _lastLen = len;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1500), flush);
  }

  Future<void> flush() async {
    _debounce?.cancel();
    await store.save(chatId, List.of(session.messages));
  }

  /// Para de gravar (salvando o que faltou).
  Future<void> close() async {
    session.removeListener(_onChange);
    await flush();
  }
}
