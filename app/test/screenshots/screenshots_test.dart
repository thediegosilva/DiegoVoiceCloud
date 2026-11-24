// Gera as capturas de tela do README (docs/screenshots/*.png) renderizando as
// telas reais do app, com dados de exemplo.
//
//   cd app && GERAR_CAPTURAS=1 flutter test test/screenshots/
//
// (Sem GERAR_CAPTURAS=1, estes testes são pulados no `flutter test` normal.)
import 'dart:io';
import 'dart:ui' as ui;

import 'package:diego_voice_cloud/config/settings.dart';
import 'package:diego_voice_cloud/main.dart';
import 'package:diego_voice_cloud/services/chat_store.dart';
import 'package:diego_voice_cloud/services/voice_session.dart';
import 'package:diego_voice_cloud/ui/assistant_screen.dart';
import 'package:diego_voice_cloud/ui/onboarding_screen.dart';
import 'package:diego_voice_cloud/ui/session_screen.dart';
import 'package:diego_voice_cloud/ui/settings_screen.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _out = Directory('../docs/screenshots');
final _skip = Platform.environment['GERAR_CAPTURAS'] != '1';
final _boundary = GlobalKey();

class _Demo extends VoiceSession {
  _Demo({this.speaking = false});
  final bool speaking;

  @override
  bool get supportsAttachments => true;
  @override
  bool get supportsPhoto => true;
  @override
  bool get supportsCamera => true;

  @override
  Future<void> connect() async {
    audioRoute = 'bluetooth:Galaxy Buds2 Pro';
    upsertMessage('1', fromUser: true, text: 'Lexy, o que eu tenho para fazer hoje?');
    upsertMessage('2', fromUser: false,
        text: 'Você tem reunião às 15h e precisa enviar o orçamento do cliente até as 18h. Quer que eu te lembre 30 minutos antes?');
    upsertMessage('3', fromUser: true, text: 'Sim! E manda o PC abrir o Spotify.');
    upsertMessage('4', fromUser: false, text: 'Enviar para o PC: abrir o Spotify', isTool: true);
    upsertMessage('5', fromUser: false, text: 'Pronto! O PC abriu o Spotify e eu te lembro às 14h30.');
    agentLevel = 0.55;
    setState(speaking ? SessionState.speaking : SessionState.listening);
  }

  @override
  Future<void> disconnect() async => setState(SessionState.idle);
  @override
  Future<void> sendText(String text) async {}
  @override
  Future<void> setMicEnabled(bool enabled) async {}
}

Future<void> _fonts() async {
  final root = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path; // .../flutter
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      final path = '$root/bin/cache/artifacts/material_fonts/$f';
      l.addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
    }
    await l.load();
  }

  await load('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf', 'Roboto-Light.ttf']);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
  // Texto sem fonte definida usa a fonte de testes ("FlutterTest", em blocos); no
  // aparelho de verdade é a Roboto. Troca para a captura ficar igual.
  for (final f in ['Ahem', 'FlutterTest']) {
    await load(f, ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']);
  }
  for (final mono in ['/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', '/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf']) {
    if (File(mono).existsSync()) {
      final l = FontLoader('monospace')..addFont(Future.value(ByteData.sublistView(File(mono).readAsBytesSync())));
      await l.load();
      break;
    }
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  final boundary = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2); // 780 x 1688
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final jpg = img.encodeJpg(
        img.Image.fromBytes(width: image.width, height: image.height, bytes: rgba!.buffer, numChannels: 4),
        quality: 88);
    _out.createSync(recursive: true);
    File('${_out.path}/$name.jpg').writeAsBytesSync(jpg);
  });
}

Widget _app(Widget home) => RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.dark,
        darkTheme: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1FD5F9), brightness: Brightness.dark),
          scaffoldBackgroundColor: const Color(0xFF070B14),
        ),
        locale: const Locale('pt', 'BR'),
        supportedLocales: const [Locale('pt', 'BR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: home,
      ),
    );

Future<void> _precacheLogo(WidgetTester tester) async {
  await tester.runAsync(() async {
    final ctx = _boundary.currentContext!;
    await precacheImage(const AssetImage('assets/images/assistant_logo.png'), ctx);
  });
}

void main() {
  late AppSettings settings;
  late ChatStore chats;
  late Directory tmp;

  setUpAll(() async {
    await _fonts();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'onboardingDone': true,
      'userName': 'Diego',
      'birthDate': '1995-08-15',
      'geminiKeys': '[{"id":"k1","label":"x","key":"AIzaExemploExemploExemploExemplo1234"}]',
    });
    settings = await AppSettings.load();
    tmp = Directory.systemTemp.createTempSync('shots_');
    chats = ChatStore(dir: tmp);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  testWidgets('1 boas-vindas', skip: _skip, (tester) async {
    await phone(tester);
    SharedPreferences.setMockInitialValues({});
    final s = await AppSettings.load();
    await tester.pumpWidget(_app(OnboardingScreen(settings: s, onDone: () {})));
    await _precacheLogo(tester);
    await tester.enterText(find.byType(TextField).first, 'Diego');
    await tester.enterText(find.byType(TextField).last, '15081995');
    FocusManager.instance.primaryFocus?.unfocus();
    await _shot(tester, '1-boas-vindas');
  });

  testWidgets('2 inicio', skip: _skip, (tester) async {
    await phone(tester);
    await tester.pumpWidget(_app(HomeScreen(services: AppServices(settings, chats: chats))));
    await _shot(tester, '2-inicio');
  });

  testWidgets('3 conversa', skip: _skip, (tester) async {
    await phone(tester);
    await tester.pumpWidget(_app(SessionScreen(session: _Demo(speaking: true), title: 'Lexy · Modelo de IA', femaleVoice: true)));
    await _shot(tester, '3-conversa');
  });

  testWidgets('4 anexos', skip: _skip, (tester) async {
    await phone(tester);
    await tester.pumpWidget(_app(SessionScreen(session: _Demo(), title: 'Lexy · Modelo de IA', femaleVoice: true)));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byIcon(Icons.attach_file_rounded));
    await _shot(tester, '4-anexos');
  });

  testWidgets('5 assistente', skip: _skip, (tester) async {
    await phone(tester);
    await tester.pumpWidget(_app(AssistantScreen(session: _Demo(speaking: true), name: 'Lexy')));
    await _precacheLogo(tester);
    await _shot(tester, '5-assistente');
  });

  testWidgets('6 historico', skip: _skip, (tester) async {
    await phone(tester);
    await tester.runAsync(() async {
      await chats.load();
      final titles = [
        'Plano de estudos para o concurso',
        'Orçamento do site da padaria',
        'Receita de bolo de cenoura',
        'Ideias de nome para a empresa',
        'Treino de academia da semana',
        'Lista de compras do mês',
      ];
      for (var i = 0; i < titles.length; i++) {
        await chats.save('c$i', [ChatMessage(id: 'a', fromUser: true, text: titles[i])]);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await chats.togglePin('c0');
      await chats.togglePin('c1');
    });
    await tester.pumpWidget(_app(HomeScreen(services: AppServices(settings, chats: chats))));
    await tester.tap(find.byTooltip('Conversas'));
    await _shot(tester, '6-historico');
  });

  testWidgets('7 configuracoes', skip: _skip, (tester) async {
    await phone(tester);
    await tester.pumpWidget(_app(SettingsScreen(services: AppServices(settings, chats: chats))));
    await _shot(tester, '7-configuracoes');
  });
}
