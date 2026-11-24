import 'package:diego_voice_cloud/config/settings.dart';
import 'package:diego_voice_cloud/services/voice_session.dart';
import 'package:diego_voice_cloud/ui/assistant_logo.dart';
import 'package:diego_voice_cloud/ui/assistant_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSession extends VoiceSession {
  bool disconnected = false;

  @override
  Future<void> connect() async {
    setState(SessionState.listening);
    upsertMessage('u1', fromUser: true, text: 'que horas são?');
    upsertMessage('a1', fromUser: false, text: 'São dez da noite.');
  }

  @override
  Future<void> disconnect() async {
    disconnected = true;
    setState(SessionState.idle);
  }

  @override
  Future<void> sendText(String text) async {}

  @override
  Future<void> setMicEnabled(bool enabled) async {
    micEnabled = enabled;
    notifyListeners();
  }
}

void main() {
  testWidgets('mostra a conversa e a logo, e fecha sozinho após o silêncio', (tester) async {
    final session = _FakeSession();
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => AssistantScreen(session: session, name: 'Atlas', idleSeconds: 5),
          )),
          child: const Text('abrir'),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('que horas são?'), findsOneWidget);
    expect(find.text('São dez da noite.'), findsOneWidget);
    expect(find.byType(AssistantLogo), findsOneWidget);
    expect(find.text('Pode falar'), findsOneWidget);

    // Tocar na logo pausa o microfone.
    await tester.tap(find.byType(AssistantLogo));
    await tester.pump();
    expect(session.micEnabled, isFalse);

    // 6 s de silêncio → encerra e volta.
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(session.disconnected, isTrue);
    expect(find.byType(AssistantScreen), findsNothing);
  });

  test('nome muda com a voz; frases de ativação por nome', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await AppSettings.load();
    s.geminiVoice = 'Charon'; // masculina
    expect(s.assistantName, 'Diego');
    expect(s.wakePhrases, ['diego']);
    s.geminiVoice = 'Kore'; // feminina
    expect(s.assistantName, 'Lexy');
    // "Lexy" não existe no vocabulário offline: o reconhecedor ouve "léxico".
    expect(s.wakePhrases, ['lexy', 'léxico']);
    s.wakeAliases = 'Léxi';
    expect(s.wakePhrases, ['lexy', 'léxi', 'léxico']);
    // As variações são de cada nome: voltar para Diego não as usa.
    s.geminiVoice = 'Puck';
    expect(s.wakePhrases, ['diego']);
    s.maleName = 'Atlas';
    expect(s.assistantName, 'Atlas');
    expect(s.systemPrompt, contains('Seu nome é Atlas'));
    expect(s.systemPrompt.toLowerCase(), isNot(contains('jarvis')));
    expect(normalizeSpeech('Ação, Já!'), 'acao ja');
  });
}
