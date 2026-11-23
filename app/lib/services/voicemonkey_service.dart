import 'dart:convert';

import 'package:http/http.dart' as http;

/// Porta de "Controle_HOME/integrations/voicemonkey.py" + a lógica de
/// variações de ID da ferramenta controlar_casa.
class VoiceMonkeyService {
  VoiceMonkeyService(this.token);

  final String token;

  bool get enabled => token.isNotEmpty;

  Future<bool> _trigger(String id) async {
    for (final param in ['monkey', 'device']) {
      try {
        final uri = Uri.https('api-v2.voicemonkey.io', '/trigger', {'token': token, param: id});
        final res = await http.get(uri).timeout(const Duration(seconds: 10));
        final body = jsonDecode(res.body);
        if (res.statusCode == 200 && body is Map && body['success'] == true) return true;
      } catch (_) {}
    }
    return false;
  }

  Future<String> controlarCasa(String dispositivo, String acao) async {
    if (!enabled) return 'Voice Monkey não configurado (token ausente nas configurações).';
    final base = dispositivo.toLowerCase().replaceAll(' ', '');
    final ligar = acao.toLowerCase().trim() != 'desligar';
    final variacoes = ligar
        ? ['ligar-$base', 'ligar$base', base, '$base-on', '$base-ligar', 'ligar_$base']
        : ['desligar-$base', 'desligar$base', '$base-off', '$base-desligar', 'desligar_$base'];
    for (final v in variacoes) {
      if (await _trigger(v)) {
        return "Comando '${ligar ? 'ligar' : 'desligar'}' para '$dispositivo' executado (ID: $v).";
      }
    }
    return 'Não consegui ${ligar ? 'ligar' : 'desligar'} $dispositivo. '
        'Tentei os IDs: ${variacoes.join(', ')}. Verifique o painel do Voice Monkey.';
  }
}
