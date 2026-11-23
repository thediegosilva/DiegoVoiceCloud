import 'package:url_launcher/url_launcher.dart';

import 'pc_control.dart';
import 'screen_bridge.dart';
import 'voicemonkey_service.dart';

/// Ferramentas que o Jarvis pode chamar no modo "Gemini direto".
/// (No modo LiveKit, as ferramentas rodam no agente Python do backend.)
class ToolRegistry {
  ToolRegistry({required this.voiceMonkey, required this.pc, required this.pcEnabled});

  final VoiceMonkeyService voiceMonkey;
  final PcControl pc;
  final bool pcEnabled;

  /// Ponte de tela ativa (definida pela sessão) e permissão de controle.
  ScreenBridge? Function() screen = () => null;
  bool Function() controlAllowed = () => false;

  bool get _screenTools => pcEnabled && ScreenBridge.supported;

  static Map<String, dynamic> _fn(String name, String desc, [Map<String, String> params = const {}, List<String>? required]) {
    final props = <String, dynamic>{};
    params.forEach((k, v) {
      final type = v.startsWith('int:') ? 'INTEGER' : 'STRING';
      props[k] = {'type': type, 'description': v.replaceFirst('int:', '')};
    });
    return {
      'name': name,
      'description': desc,
      if (params.isNotEmpty)
        'parameters': {'type': 'OBJECT', 'properties': props, 'required': required ?? params.keys.toList()},
    };
  }

  List<Map<String, dynamic>> get declarations => [
        _fn('pesquisar_na_web', 'Faz uma busca no Google, abre a busca do YouTube ou abre uma URL no navegador.', {
          'consulta': 'O termo de busca ou a URL',
          'tipo': "'google' (padrão), 'youtube' ou 'url'",
        }, ['consulta']),
        if (voiceMonkey.enabled)
          _fn('controlar_casa',
              'Controla dispositivos inteligentes da casa (luzes, ventilador, ar-condicionado, tomada) via Voice Monkey + Alexa. Use quando o usuário pedir para ligar ou desligar algo em casa.',
              {'dispositivo': "Nome do dispositivo (ex: 'ventilador', 'luz', 'ar')", 'acao': "'ligar' (padrão) ou 'desligar'"},
              ['dispositivo']),
        if (pcEnabled && PcControl.supported) ...[
          _fn('abrir_aplicativo', "Abre um aplicativo pelo nome (ex: 'calculadora', 'vscode', 'spotify', 'terminal').", {'nome_app': 'Nome do aplicativo'}),
          _fn('fechar_programa', "Fecha um programa pelo nome do processo (ex: 'chrome', 'spotify').", {'programa': 'Nome do processo'}),
          _fn('criar_pasta', "Cria uma pasta. Caminhos relativos ficam na Área de Trabalho (ex: 'Projetos/Python', 'documentos/Notas').", {'caminho': 'Caminho da pasta'}),
          _fn('deletar_item', 'Deleta um arquivo ou pasta (o usuário confirma na tela).', {'caminho': 'Caminho do item'}),
          _fn('limpar_diretorio', 'Remove todo o conteúdo de uma pasta, sem apagar a pasta (o usuário confirma na tela).', {'caminho': 'Caminho da pasta'}),
          _fn('mover_item', 'Move um arquivo ou pasta.', {'origem': 'Caminho de origem', 'destino': 'Caminho de destino'}),
          _fn('copiar_item', 'Copia um arquivo ou pasta.', {'origem': 'Caminho de origem', 'destino': 'Caminho de destino'}),
          _fn('renomear_item', 'Renomeia um arquivo ou pasta.', {'caminho': 'Caminho atual', 'novo_nome': 'Novo nome'}),
          _fn('organizar_pasta', 'Organiza os arquivos de uma pasta em subpastas por tipo (Imagens, Documentos, etc.).', {'caminho': 'Caminho da pasta'}),
          _fn('compactar_pasta', 'Compacta uma pasta em um arquivo .zip.', {'caminho': 'Caminho da pasta'}),
          _fn('abrir_pasta', 'Abre uma pasta no gerenciador de arquivos pelo nome.', {'nome_pasta': 'Nome da pasta'}),
          _fn('buscar_e_abrir_arquivo', 'Busca um arquivo por nome (Área de Trabalho, Documentos, Downloads) e o abre.', {'nome_arquivo': 'Nome ou parte do nome'}),
          _fn('controle_volume', 'Ajusta o volume do sistema.', {'nivel': 'int:Volume de 0 a 100'}),
          _fn('controle_brilho', 'Ajusta o brilho da tela.', {'nivel': 'int:Brilho de 0 a 100'}),
          _fn('energia_pc', "Controla a energia do PC. Ações: 'desligar', 'reiniciar', 'bloquear'.", {'acao': 'desligar | reiniciar | bloquear'}),
        ],
        if (_screenTools) ...[
          _fn('tela_clicar',
              'Clica na tela do PC (só funciona com a tela compartilhada e o controle permitido pelo usuário). '
                  'x e y são de 0 a 1000 sobre a imagem MAIS RECENTE da tela: x da esquerda (0) para a direita (1000), '
                  'y do topo (0) para baixo (1000). Mire no centro do botão/campo.',
              {
                'x': 'int:Posição horizontal 0-1000',
                'y': 'int:Posição vertical 0-1000',
                'botao': "'esquerdo' (padrão), 'direito' ou 'meio'",
                'duplo': "'sim' para clique duplo, senão 'nao'",
              },
              ['x', 'y']),
          _fn('tela_digitar', 'Digita um texto no PC, onde o cursor estiver (clique no campo antes).', {'texto': 'Texto a digitar'}),
          _fn('tela_tecla', "Pressiona uma tecla ou atalho no PC. Ex.: 'enter', 'esc', 'tab', 'ctrl+c', 'ctrl+v', 'alt+tab', 'super', 'ctrl+l'.",
              {'combinacao': 'Tecla ou atalho com +'}),
          _fn('tela_rolar', 'Rola a página no PC.', {'direcao': "'baixo' ou 'cima'", 'quantidade': 'int:Quantos passos (1-30, padrão 5)'},
              ['direcao']),
        ],
      ];

  Future<String> execute(String name, Map<String, dynamic> args) async {
    String s(String k, [String def = '']) => (args[k] ?? def).toString();
    int i(String k) => (args[k] is num) ? (args[k] as num).toInt() : int.tryParse(s(k)) ?? 50;

    switch (name) {
      case 'pesquisar_na_web':
        return _pesquisar(s('consulta'), s('tipo', 'google'));
      case 'controlar_casa':
        return voiceMonkey.controlarCasa(s('dispositivo'), s('acao', 'ligar'));
    }
    if (!pcEnabled) return 'Ferramentas de PC desativadas nas configurações.';
    if (name.startsWith('tela_')) return _tela(name, args, s, i);
    return switch (name) {
      'abrir_aplicativo' => pc.abrirAplicativo(s('nome_app')),
      'fechar_programa' => pc.fecharPrograma(s('programa')),
      'criar_pasta' => pc.criarPasta(s('caminho')),
      'deletar_item' => pc.deletarItem(s('caminho')),
      'limpar_diretorio' => pc.limparDiretorio(s('caminho')),
      'mover_item' => pc.moverItem(s('origem'), s('destino')),
      'copiar_item' => pc.copiarItem(s('origem'), s('destino')),
      'renomear_item' => pc.renomearItem(s('caminho'), s('novo_nome')),
      'organizar_pasta' => pc.organizarPasta(s('caminho')),
      'compactar_pasta' => pc.compactarPasta(s('caminho')),
      'abrir_pasta' => pc.abrirPasta(s('nome_pasta')),
      'buscar_e_abrir_arquivo' => pc.buscarEAbrirArquivo(s('nome_arquivo')),
      'controle_volume' => pc.controleVolume(i('nivel')),
      'controle_brilho' => pc.controleBrilho(i('nivel')),
      'energia_pc' => pc.energiaPc(s('acao')),
      _ => Future.value('Ferramenta desconhecida: $name'),
    };
  }

  Future<String> _tela(String name, Map<String, dynamic> args, String Function(String, [String]) s, int Function(String) i) async {
    final bridge = screen();
    if (bridge == null || !bridge.ready) {
      return 'A tela não está compartilhada. Peça ao usuário para tocar no botão de compartilhar tela.';
    }
    if (!controlAllowed() || !bridge.control) {
      return 'O usuário não permitiu o controle de mouse e teclado. Peça para ele ativar o botão do mouse na chamada.';
    }
    return switch (name) {
      'tela_clicar' => bridge.command({
          'cmd': 'click',
          'x': i('x'),
          'y': i('y'),
          'button': s('botao', 'esquerdo'),
          'double': s('duplo', 'nao').toLowerCase().startsWith('s'),
        }),
      'tela_digitar' => bridge.command({'cmd': 'type', 'text': s('texto')}),
      'tela_tecla' => bridge.command({'cmd': 'key', 'combo': s('combinacao')}),
      'tela_rolar' => bridge.command({
          'cmd': 'scroll',
          'dir': s('direcao', 'baixo').toLowerCase().startsWith('c') ? 'up' : 'down',
          'amount': args.containsKey('quantidade') ? i('quantidade') : 5,
        }),
      _ => Future.value('Ferramenta desconhecida: $name'),
    };
  }

  Future<String> _pesquisar(String consulta, String tipo) async {
    final Uri uri;
    switch (tipo.toLowerCase()) {
      case 'youtube':
        uri = Uri.https('www.youtube.com', '/results', {'search_query': consulta});
      case 'url':
        final u = consulta.startsWith('http') ? consulta : 'https://$consulta';
        uri = Uri.parse(u);
        if (uri.scheme != 'http' && uri.scheme != 'https') return 'URL inválida.';
      default:
        uri = Uri.https('www.google.com', '/search', {'q': consulta});
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    return ok ? 'Abrindo $uri' : 'Não consegui abrir o navegador.';
  }
}
