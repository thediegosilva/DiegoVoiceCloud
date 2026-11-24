import 'package:diego_voice_cloud/config/settings.dart';
import 'package:diego_voice_cloud/main.dart';
import 'package:diego_voice_cloud/ui/api_keys_card.dart';
import 'package:diego_voice_cloud/ui/onboarding_screen.dart';
import 'package:diego_voice_cloud/ui/settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('primeira abertura: pergunta nome e nascimento, depois vai para a tela inicial', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    expect(settings.mode, ConnectionMode.gemini, reason: 'Modelo de IA vem marcado por padrão');
    expect(settings.assistantName, 'Lexy', reason: 'voz padrão Kore');

    await tester.pumpWidget(AssistantApp(services: AppServices(settings)));
    await tester.pump();
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.text('Olá! Eu sou Lexy.'), findsOneWidget);

    final start = find.widgetWithText(FilledButton, 'Começar');
    expect(tester.widget<FilledButton>(start).onPressed, isNull, reason: 'sem dados, não dá para começar');

    await tester.enterText(find.widgetWithText(TextField, 'Como você quer que eu te chame?'), 'Diego');
    await tester.enterText(find.widgetWithText(TextField, 'Data de nascimento'), '15081995');
    await tester.pump();
    expect(find.text('15/08/1995'), findsOneWidget, reason: 'barras colocadas sozinhas');

    await tester.tap(start);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(OnboardingScreen), findsNothing);
    expect(find.text('Iniciar chamada'), findsOneWidget);

    expect(settings.onboardingDone, isTrue);
    expect(settings.userName, 'Diego');
    expect(settings.birthDate, DateTime(1995, 8, 15));
    expect(settings.userId, 'diego');
  });

  testWidgets('calendário abre em português', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    await tester.pumpWidget(AssistantApp(services: AppServices(settings)));
    await tester.pump();
    // (a logo animada nunca "assenta", então espera um tempo fixo)
    await tester.tap(find.byTooltip('Escolher no calendário'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Cancelar'), findsOneWidget);
    expect(find.text('Data de nascimento'), findsWidgets);
    await tester.tap(find.text('Cancelar'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Cancelar'), findsNothing);
  });

  test('datas inválidas são recusadas', () {
    expect(OnboardingScreen.parseDate('31/02/2000'), isNull);
    expect(OnboardingScreen.parseDate('10/10/1800'), isNull);
    expect(OnboardingScreen.parseDate('01/01/3000'), isNull);
    expect(OnboardingScreen.parseDate('1/1/2000'), isNull);
    expect(OnboardingScreen.parseDate('29/02/2000'), DateTime(2000, 2, 29));
  });

  test('a IA sabe o nome, a idade e o aniversário', () async {
    SharedPreferences.setMockInitialValues({'userName': 'Diego', 'birthDate': '1995-08-15'});
    final s = await AppSettings.load();
    final normal = s.userContext(DateTime(2026, 11, 23));
    expect(normal, contains('se chama Diego'));
    expect(normal, contains('15/08/1995 (31 anos)'));
    expect(normal, isNot(contains('ANIVERSÁRIO')));
    final niver = s.userContext(DateTime(2026, 8, 15));
    expect(niver, contains('31 anos'));
    expect(niver, contains('HOJE É ANIVERSÁRIO'));
    expect(s.userContext(DateTime(2026, 8, 14)), contains('30 anos'));
  });

  testWidgets('configurações abrem com as chaves da API em primeiro', (tester) async {
    SharedPreferences.setMockInitialValues({'onboardingDone': true});
    final settings = await AppSettings.load();
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(services: AppServices(settings))));
    await tester.pump();
    final list = tester.widget<ListView>(find.byType(ListView).first);
    final first = (list.childrenDelegate as SliverChildListDelegate).children.take(2).toList();
    expect(first[1], isA<ApiKeysCard>());
    expect(tester.getTopLeft(find.byType(ApiKeysCard)).dy,
        lessThan(tester.getTopLeft(find.text('Assistente')).dy));
  });
}
