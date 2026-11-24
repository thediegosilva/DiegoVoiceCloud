import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:diego_voice_cloud/services/attachments.dart';
import 'package:diego_voice_cloud/services/voice_session.dart';
import 'package:diego_voice_cloud/ui/session_screen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

class _Fake extends VoiceSession {
  final docs = <String>[];
  bool hungUp = false;

  @override
  bool get supportsAttachments => true;
  @override
  bool get supportsPhoto => true;
  @override
  bool get supportsCamera => true;

  @override
  Future<void> connect() async {
    setState(SessionState.listening);
    upsertMessage('u', fromUser: true, text: 'Qual a capital da França?');
    upsertMessage('a', fromUser: false, text: 'A capital da França é Paris.');
  }

  @override
  Future<void> disconnect() async {
    hungUp = true;
    setState(SessionState.idle);
  }

  @override
  Future<void> sendText(String text) async => upsertMessage('t${messages.length}', fromUser: true, text: text);
  @override
  Future<void> setMicEnabled(bool enabled) async {}
  @override
  Future<void> sendDocument(String name, String text) async => docs.add('$name:$text');
}

void main() {
  test('lê .docx e texto comum', () {
    const xml = '<w:document><w:body><w:p><w:r><w:t>Olá &amp; bem-vindo</w:t></w:r></w:p>'
        '<w:p><w:r><w:t>Segunda linha</w:t></w:r></w:p></w:body></w:document>';
    final zip = Archive()..add(ArchiveFile.bytes('word/document.xml', utf8.encode(xml)));
    final docx = Uint8List.fromList(ZipEncoder().encode(zip));
    expect(Attachments.extractText('contrato.DOCX', docx), 'Olá & bem-vindo\nSegunda linha');
    expect(Attachments.extractText('a.txt', Uint8List.fromList(utf8.encode('linha 1\r\nlinha 2'))), 'linha 1\nlinha 2');
  });

  testWidgets('foto da galeria vira JPEG pequeno', (tester) async {
    final png = img.encodePng(img.Image(width: 3000, height: 2000));
    final jpeg = (await tester.runAsync(() => Attachments.toJpeg(Uint8List.fromList(png))))!;
    final decoded = img.decodeJpg(jpeg)!;
    expect(decoded.width, 1280);
    expect(decoded.height, 853);
  });

  testWidgets('chat: clipe com anexos, copiar mensagem, encerrar lá em cima', (tester) async {
    final s = _Fake();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') copied = (c.arguments as Map)['text'] as String;
      return null;
    });
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => SessionScreen(session: s, title: 'Lexy'))),
          child: const Text('abrir'),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Barra limpa: clipe, texto, microfone, enviar. Câmera/foto ficam no clipe.
    expect(find.byIcon(Icons.attach_file_rounded), findsOneWidget);
    expect(find.byIcon(Icons.photo_camera_rounded), findsNothing);

    // Copiar a resposta da IA.
    await tester.tap(find.text('Copiar').last);
    await tester.pump();
    expect(copied, 'A capital da França é Paris.');

    // Menu do clipe.
    await tester.tap(find.byIcon(Icons.attach_file_rounded));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Foto da galeria'), findsOneWidget);
    expect(find.text('Documento de texto'), findsOneWidget);
    expect(find.text('Tirar foto'), findsOneWidget);
    expect(find.text('Câmera ao vivo'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // fecha o menu
    await tester.pump(const Duration(milliseconds: 500));

    // Encerrar fica na barra de cima.
    final end = find.byTooltip('Encerrar conversa');
    expect(find.descendant(of: find.byType(AppBar), matching: end), findsOneWidget);
    await tester.tap(end);
    await tester.pump(const Duration(milliseconds: 500));
    expect(s.hungUp, isTrue);
  });
}
