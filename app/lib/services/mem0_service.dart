import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Cliente REST mínimo do Mem0 (equivalente ao AsyncMemoryClient do Python).
class Mem0Service {
  Mem0Service(this.apiKey);

  final String apiKey;
  static const _base = 'https://api.mem0.ai';

  bool get enabled => apiKey.isNotEmpty;

  Map<String, String> get _headers => {
        'Authorization': 'Token $apiKey',
        'Content-Type': 'application/json',
      };

  /// Busca memórias do usuário (mesma query usada no agent.py original).
  Future<List<String>> loadMemories(String userId) async {
    if (!enabled) return [];
    try {
      final res = await http.post(
        Uri.parse('$_base/v2/memories/search/'),
        headers: _headers,
        body: jsonEncode({
          'query': 'histórico, preferências e informações pessoais do usuário',
          'filters': {'user_id': userId},
          'top_k': 20,
        }),
      );
      if (res.statusCode != 200) {
        debugPrint('[Mem0] search falhou: ${res.statusCode} ${res.body}');
        return [];
      }
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      final List results = decoded is Map ? (decoded['results'] ?? []) : (decoded as List);
      return [
        for (final r in results)
          if (r is Map && (r['memory'] ?? r['text'] ?? r['content']) != null)
            (r['memory'] ?? r['text'] ?? r['content']).toString(),
      ];
    } catch (e) {
      debugPrint('[Mem0] erro ao carregar: $e');
      return [];
    }
  }

  /// Salva a conversa (lista de {role, content}) para o Mem0 extrair fatos.
  Future<void> saveConversation(String userId, List<Map<String, String>> messages) async {
    if (!enabled || messages.isEmpty) return;
    try {
      final res = await http.post(
        Uri.parse('$_base/v1/memories/'),
        headers: _headers,
        body: jsonEncode({'messages': messages, 'user_id': userId}),
      );
      debugPrint('[Mem0] save: ${res.statusCode}');
    } catch (e) {
      debugPrint('[Mem0] erro ao salvar: $e');
    }
  }
}
