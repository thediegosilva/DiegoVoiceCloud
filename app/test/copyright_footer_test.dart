import 'package:diego_voice_cloud/ui/copyright_footer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('mostra os direitos e pergunta antes de abrir o site', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: CopyrightFooter()))));
    expect(find.textContaining('Diego Silva. Todos os direitos reservados.'), findsOneWidget);
    await tester.tap(find.text('thediegosilva.github.io'));
    await tester.pumpAndSettle();
    expect(find.text('Ir para o site?'), findsOneWidget);
    await tester.tap(find.text('Agora não'));
    await tester.pumpAndSettle();
    expect(find.text('Ir para o site?'), findsNothing);
  });
}
