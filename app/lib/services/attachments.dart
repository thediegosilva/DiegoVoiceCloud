import 'dart:convert';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Prepara anexos (fotos da galeria e documentos) para mandar à IA.
class Attachments {
  /// Extensões de documento lidas como texto.
  static const textExtensions = [
    'txt', 'md', 'csv', 'tsv', 'json', 'xml', 'html', 'htm', 'log', 'yaml', 'yml', 'ini', 'conf', 'srt',
    'py', 'dart', 'js', 'ts', 'java', 'kt', 'c', 'cpp', 'h', 'cs', 'go', 'rs', 'php', 'rb', 'sh', 'sql', 'css',
    'docx',
  ];

  /// Limite de texto enviado à IA (o resto é cortado, com aviso).
  static const maxChars = 30000;

  /// Converte qualquer imagem que o aparelho saiba abrir (JPEG, PNG, HEIC,
  /// WebP…) em JPEG com no máximo [maxSide] px no maior lado.
  static Future<Uint8List> toJpeg(Uint8List bytes, {int maxSide = 1280}) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final desc = await ui.ImageDescriptor.encoded(buffer);
    final w = desc.width, h = desc.height;
    final scale = (w > h ? w : h) > maxSide ? maxSide / (w > h ? w : h) : 1.0;
    final codec = await desc.instantiateCodec(targetWidth: (w * scale).round(), targetHeight: (h * scale).round());
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final tw = image.width, th = image.height;
    image.dispose();
    codec.dispose();
    desc.dispose();
    buffer.dispose();
    if (rgba == null) throw Exception('Não consegui ler a imagem.');
    return compute(_encodeJpeg, (rgba.buffer.asUint8List(), tw, th));
  }

  static Uint8List _encodeJpeg((Uint8List, int, int) a) {
    final im = img.Image.fromBytes(width: a.$2, height: a.$3, bytes: a.$1.buffer, numChannels: 4);
    return img.encodeJpg(im, quality: 85);
  }

  /// Texto do documento (.docx é aberto; os demais são lidos como texto).
  static String extractText(String name, Uint8List bytes) {
    if (name.toLowerCase().endsWith('.docx')) return _docx(bytes);
    return utf8.decode(bytes, allowMalformed: true).replaceAll('\r\n', '\n');
  }

  static String _docx(Uint8List bytes) {
    final zip = ZipDecoder().decodeBytes(bytes);
    final doc = zip.findFile('word/document.xml');
    if (doc == null) throw Exception('Arquivo .docx inválido.');
    final xml = utf8.decode(doc.content as List<int>, allowMalformed: true);
    return xml
        .replaceAll(RegExp(r'</w:p>'), '\n')
        .replaceAll(RegExp(r'<w:tab/>'), '\t')
        .replaceAll(RegExp(r'<w:br/>'), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }
}
