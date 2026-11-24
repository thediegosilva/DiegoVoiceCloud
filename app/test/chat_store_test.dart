import 'dart:io';

import 'package:diego_voice_cloud/config/settings.dart';
import 'package:diego_voice_cloud/services/chat_store.dart';
import 'package:diego_voice_cloud/services/voice_session.dart';
import 'package:diego_voice_cloud/ui/chat_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<ChatMessage> conv(String pergunta, [String resposta = 'Resposta.']) => [
      ChatMessage(id: '1', fromUser: true, text: pergunta),
      ChatMessage(id: 't', fromUser: false, text: '✅ Pesquisar', isTool: true),
      ChatMessage(id: '2', fromUser: false, text: resposta),
    ];

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('conversas_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('salva só no aparelho, com título automático, e sobrevive a reabrir o app', () async {
    final s = ChatStore(dir: dir);
    await s.load();
    await s.save('a', conv('Qual a previsão do tempo para amanhã no Rio de Janeiro e em Niterói?'));
    await s.save('vazia', [ChatMessage(id: 'x', fromUser: false, text: '', isTool: false)]);
    expect(s.chats, hasLength(1), reason: 'conversa sem conteúdo não é salva');
    expect(s.chats.single.title, 'Qual a previsão do tempo para amanhã no Ri…');

    final again = ChatStore(dir: dir);
    await again.load();
    final msgs = await again.messages('a');
    expect(msgs.map((m) => m.text), ['Qual a previsão do tempo para amanhã no Rio de Janeiro e em Niterói?', '✅ Pesquisar', 'Resposta.']);
    expect(msgs[1].isTool, isTrue);
  });

  test('renomear, fixar até 5, excluir uma e excluir tudo', () async {
    final s = ChatStore(dir: dir);
    await s.load();
    for (var i = 1; i <= 7; i++) {
      await s.save('c$i', conv('Pergunta $i'));
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(s.chats.first.id, 'c7', reason: 'mais recente primeiro');

    await s.rename('c3', 'Receita de bolo');
    await s.save('c3', conv('Pergunta 3', 'mais uma'));
    expect(s.byId('c3')!.title, 'Receita de bolo', reason: 'nome dado pelo usuário não muda sozinho');

    for (var i = 1; i <= 5; i++) {
      expect(await s.togglePin('c$i'), isTrue);
    }
    expect(await s.togglePin('c6'), isFalse, reason: 'máximo de 5 fixadas');
    expect(s.chats.take(5).map((c) => c.id), ['c1', 'c2', 'c3', 'c4', 'c5'], reason: 'fixadas no topo');
    expect(await s.togglePin('c2'), isTrue); // desafixa
    expect(await s.togglePin('c6'), isTrue);

    await s.delete('c4');
    expect(s.byId('c4'), isNull);
    expect(File('${dir.path}/c4.json').existsSync(), isFalse, reason: 'arquivo apagado de verdade');

    final reopened = ChatStore(dir: dir);
    await reopened.load();
    expect(reopened.pinnedCount, 4, reason: 'c1, c3, c5, c6 (a c4 foi excluída)');
    expect(reopened.byId('c3')!.title, 'Receita de bolo');

    await s.deleteAll();
    expect(s.chats, isEmpty);
    expect(dir.listSync().whereType<File>().where((f) => !f.path.endsWith('indice.json')), isEmpty);
  });

  test('grava a conversa durante a sessão e ao fechar; continuar mostra o histórico', () async {
    final store = ChatStore(dir: dir);
    await store.load();
    final session = _FakeSession();
    final rec = ChatRecorder(store, session, 'sess');
    session.upsertMessage('u1', fromUser: true, text: 'Me lembra de beber água');
    session.upsertMessage('a1', fromUser: false, text: 'Claro!');
    await Future<void>.delayed(const Duration(milliseconds: 1700)); // espera do salvamento automático
    expect(store.byId('sess')?.title, 'Me lembra de beber água');
    session.upsertMessage('u2', fromUser: true, text: 'Valeu');
    await rec.close(); // fecha antes do tempo: salva na hora
    expect((await store.messages('sess')).last.text, 'Valeu');

    // Continuar: a nova sessão começa com as mensagens antigas e grava na mesma conversa.
    final history = await store.messages('sess');
    final s2 = _FakeSession()..messages.addAll(history);
    final rec2 = ChatRecorder(store, s2, 'sess');
    s2.upsertMessage('u3', fromUser: true, text: 'E amanhã também');
    await rec2.close();
    expect((await store.messages('sess')).map((m) => m.text),
        ['Me lembra de beber água', 'Claro!', 'Valeu', 'E amanhã também']);
    expect(store.chats, hasLength(1));
  });

  test('padrões novos e nomes automáticos das chaves', () async {
    SharedPreferences.setMockInitialValues({});
    final st = await AppSettings.load();
    expect(st.halfDuplex, isTrue);
    expect(st.wakeIdleSeconds, 30);
    await st.addKey('AIzaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1');
    await st.addKey('AIzaBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB2');
    await st.addKey('AIzaCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC3');
    expect(st.geminiKeys.map((k) => k.label), ['CHAVE API 1', 'CHAVE API 2', 'CHAVE API 3']);
    await st.removeKey(st.geminiKeys[1].id);
    expect(st.geminiKeys.map((k) => k.label), ['CHAVE API 1', 'CHAVE API 2'], reason: 'renumera sem buracos');
  });

  testWidgets('lateral mostra fixadas e recentes; excluir tudo pede confirmação', (tester) async {
    // Arquivos de verdade só dentro do runAsync (fora dele o relógio é falso).
    late ChatStore s;
    await tester.runAsync(() async {
      s = ChatStore(dir: dir);
      await s.load();
      await s.save('x', conv('Plano de estudos'));
      await s.save('y', conv('Lista de compras'));
      await s.togglePin('x');
    });
    ChatSummary? opened;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(drawer: ChatHistoryDrawer(store: s, onOpen: (c) => opened = c, onNew: () {}), body: const SizedBox()),
    ));
    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();
    expect(find.text('Fixadas (1/5)'), findsOneWidget);
    expect(find.text('Recentes'), findsOneWidget);
    expect(find.text('Salvas só neste aparelho.'), findsOneWidget);

    await tester.tap(find.text('Lista de compras'));
    await tester.pumpAndSettle();
    expect(opened?.id, 'y');

    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Excluir tudo'));
    await tester.pumpAndSettle();
    expect(find.text('Excluir todas as conversas?'), findsOneWidget);
    // Cancelar não apaga nada (a exclusão em si é testada acima).
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(s.chats, hasLength(2));
  });
}

class _FakeSession extends VoiceSession {
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> sendText(String text) async {}
  @override
  Future<void> setMicEnabled(bool enabled) async {}
}
