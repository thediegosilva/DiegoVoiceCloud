import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/settings.dart';
import '../tool_registry.dart';
import 'mesh_service.dart';

/// Executa, sem voz e sem tela, as tarefas que chegam de outro aparelho.
///
/// Usa o Gemini por texto (generateContent) com as mesmas ferramentas do modo
/// Gemini direto. Ações perigosas continuam pedindo confirmação na tela deste
/// aparelho (terminal, apagar, desligar).
class RemoteTaskRunner {
  RemoteTaskRunner({required this.settings, required this.tools, required this.mesh});

  final AppSettings settings;
  final ToolRegistry tools;
  final MeshService mesh;

  static const _maxTurns = 8;

  Future<String> run(MeshMessage task) async {
    final keys = settings.geminiKeys.map((k) => k.key).where((k) => k.isNotEmpty).toList();
    if (keys.isEmpty) return 'O ${mesh.myName} não tem chave do Modelo de IA configurada.';
    final active = settings.geminiApiKey;
    if (active.isNotEmpty) {
      keys
        ..remove(active)
        ..insert(0, active);
    }

    // Repasses feitos por esta tarefa contam um salto a mais (evita loops).
    tools.meshHops = task.hops + 1;

    final system = '${settings.systemPrompt}\n\n'
        'Seu nome é ${settings.assistantName}. Você está rodando no aparelho "${mesh.myName}" do usuário.\n${settings.userContext()}\n'
        'Você recebeu um pedido de outro aparelho do próprio usuário ("${task.from}") pela rede privada e cifrada dele. '
        'Ninguém está olhando a tela agora: execute o pedido com as ferramentas disponíveis e responda com um resumo curto '
        '(1 a 3 frases) do que fez ou do que descobriu. Se o pedido for para repassar algo a outro aparelho, use enviar_para_aparelho. '
        'Não invente resultados; se não der para fazer aqui, diga por quê.';

    final contents = <Map<String, dynamic>>[
      {
        'role': 'user',
        'parts': [
          {'text': 'Pedido vindo do aparelho "${task.from}": ${task.text}'}
        ]
      }
    ];
    final decls = tools.declarations.where((d) => d['name'] != 'executar_tarefa_no_pc').toList();

    for (var turn = 0; turn < _maxTurns; turn++) {
      final res = await _generate(keys, system, contents, decls);
      final cand = (res['candidates'] as List?)?.firstOrNull as Map<String, dynamic>?;
      final content = cand?['content'] as Map<String, dynamic>?;
      final parts = (content?['parts'] as List?) ?? const [];
      if (content == null || parts.isEmpty) return 'O ${mesh.myName} não conseguiu gerar resposta.';
      contents.add({'role': 'model', 'parts': parts});

      final calls = [
        for (final p in parts)
          if ((p as Map)['functionCall'] != null) p['functionCall'] as Map
      ];
      if (calls.isEmpty) {
        final text = parts.map((p) => (p as Map)['text'] ?? '').join().trim();
        return text.isEmpty ? 'Feito.' : text;
      }
      final responses = <Map<String, dynamic>>[];
      for (final call in calls) {
        final name = '${call['name']}';
        final args = (call['args'] as Map?)?.cast<String, dynamic>() ?? {};
        String result;
        try {
          result = await tools.execute(name, args);
        } catch (e) {
          result = 'Erro: $e';
        }
        responses.add({
          'functionResponse': {
            'name': name,
            'response': {'result': result}
          }
        });
      }
      contents.add({'role': 'user', 'parts': responses});
    }
    return 'O ${mesh.myName} parou após muitos passos sem concluir.';
  }

  Future<Map<String, dynamic>> _generate(
      List<String> keys, String system, List<Map<String, dynamic>> contents, List<Map<String, dynamic>> decls) async {
    final body = jsonEncode({
      'systemInstruction': {
        'parts': [
          {'text': system}
        ]
      },
      'contents': contents,
      if (decls.isNotEmpty)
        'tools': [
          {'functionDeclarations': decls}
        ],
    });
    var lastError = 'nenhum modelo respondeu';
    nextModel:
    for (final model in settings.agentModelList) {
      for (final key in keys) {
        final http.Response r;
        try {
          r = await http
              .post(
                Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
                headers: {'Content-Type': 'application/json', 'x-goog-api-key': key},
                body: body,
              )
              .timeout(const Duration(seconds: 60));
        } on TimeoutException {
          lastError = 'tempo esgotado em $model';
          continue nextModel;
        }
        if (r.statusCode == 200) return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        lastError = 'HTTP ${r.statusCode} em $model';
        if (r.statusCode == 429) continue; // cota desta chave → próxima chave
        continue nextModel; // sobrecarga / modelo indisponível → próximo modelo
      }
    }
    throw Exception(lastError);
  }
}
