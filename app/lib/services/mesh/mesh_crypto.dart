import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart';

/// Chaves derivadas do código secreto da rede.
///
/// Do código saem duas coisas independentes:
/// - [topic]: o nome do canal no servidor de recados (aleatório, sem relação
///   visível com o código);
/// - a chave AES-256-GCM que cifra e autentica cada mensagem.
///
/// O servidor só vê bytes cifrados num canal com nome aleatório. Sem o código
/// ninguém lê, e mensagens forjadas ou alteradas são descartadas (GCM).
class MeshCrypto {
  MeshCrypto._(this.topic, this._key);

  final String topic;
  final SecretKey _key;

  static final _aes = AesGcm.with256bits();

  /// Código mínimo aceito (o gerado tem 52 letras/números).
  static const minCodeLength = 20;

  static String normalize(String code) => code.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();

  /// Deriva as chaves (PBKDF2 com 60 mil rodadas — leva ~1 s; feito uma vez).
  static Future<MeshCrypto> derive(String code) async {
    final norm = normalize(code);
    if (norm.length < minCodeLength) {
      throw ArgumentError('Código curto demais (mínimo $minCodeLength caracteres).');
    }
    final pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 60000, bits: 256);
    final master = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(norm)),
      nonce: utf8.encode('assistente-elo-v1'),
    );
    final m = await master.extractBytes();
    List<int> sub(String label) => c.Hmac(c.sha256, m).convert(utf8.encode(label)).bytes;
    final topicId = sub('topic').take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return MeshCrypto._('elo/$topicId', SecretKey(sub('aes-gcm-key')));
  }

  /// Cifra o JSON da mensagem. Formato: nonce(12) | cifrado | tag(16).
  Future<Uint8List> seal(Map<String, dynamic> msg) async {
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(msg)),
      secretKey: _key,
      aad: utf8.encode(topic),
    );
    return Uint8List.fromList([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Decifra; devolve null se a mensagem não for de um aparelho com o código.
  Future<Map<String, dynamic>?> open(Uint8List data) async {
    if (data.length < 12 + 16 + 2) return null;
    try {
      final box = SecretBox(
        data.sublist(12, data.length - 16),
        nonce: data.sublist(0, 12),
        mac: Mac(data.sublist(data.length - 16)),
      );
      final plain = await _aes.decrypt(box, secretKey: _key, aad: utf8.encode(topic));
      return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    } catch (_) {
      return null; // chave errada, adulterada ou lixo
    }
  }

  /// Gera um código novo: 32 bytes aleatórios em base32, em grupos de 4.
  static String generateCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // sem 0/O, 1/I
    final r = Random.secure();
    final chars = List.generate(52, (_) => alphabet[r.nextInt(alphabet.length)]);
    final groups = <String>[];
    for (var i = 0; i < chars.length; i += 4) {
      groups.add(chars.sublist(i, i + 4).join());
    }
    return groups.join('-');
  }
}
