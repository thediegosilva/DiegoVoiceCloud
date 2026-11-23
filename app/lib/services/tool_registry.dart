import 'package:url_launcher/url_launcher.dart';

import 'pc_control.dart';
import 'screen_bridge.dart';
import 'terminal_service.dart';
import 'voicemonkey_service.dart';

/// Ferramentas que o Jarvis pode chamar no modo "Gemini direto".
/// (No modo LiveKit, as ferramentas rodam no agente Python do backend.)
class ToolRegistry {
  ToolRegistry({required this.voiceMonkey, required this.pc, required this.pcEnabled, this.terminal});

  /// Terminal do PC (null = indisponível neste aparelho).
  final TerminalService? terminal;

  final VoiceMonkeyService voiceMonkey;
  final PcControl pc;
  final bool pcEnabled;

  /// Ponte de tela ativa (definida pela sessão) e permissão de controle.
  ScreenBridge? Function() screen = () => null;
  bool Function() controlAllowed = () => false;

  /// Roda uma tarefa no PC com o agente de computador (definido pela sessão).
  Future<String> Function(String objetivo)? runComputerTask;

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
        if (pcEnabled && terminal != null)
          _fn('executar_comando',
              'Roda um comando no terminal do PC (bash no Linux, PowerShell no Windows) e devolve a saída. '
                  'Use para tarefas como listar arquivos, ver uso de disco, git, rodar scripts, instalar pacotes do usuário (pip/npm). '
                  'A pasta atual persiste entre comandos (use "cd pasta" sozinho para mudar). '
                  'Comandos interativos não funcionam (sem teclado); limite de 60 s — servidores/longos: "nohup … &". '
                  'Pode ser que o usuário precise confirmar.',
              {'comando': 'O comando completo'}),
        if (_screenTools)
          _fn('executar_tarefa_no_pc',
              'Executa uma tarefa no PC do usuário vendo a tela e usando mouse, teclado e terminal, em vários passos, '
                  'até concluir (ex.: abrir sites, pesquisar, clicar, tocar vídeos, preencher campos, mexer em programas). '
                  'Descreva o objetivo COMPLETO com todos os detalhes do pedido. Pode levar até alguns minutos. '
                  'Devolve um resumo do que foi feito ou uma pergunta para o usuário.',
              {'objetivo': 'O objetivo completo, ex.: "Abrir o Firefox, ir ao YouTube, pesquisar vídeo de gatinho e colocar um para tocar"'}),
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
    if (name == 'executar_tarefa_no_pc') {
      return runComputerTask?.call(s('objetivo')) ?? Future.value('Uso do computador indisponível neste aparelho.');
    }
    if (name == 'executar_comando') {
      return terminal?.run(s('comando')) ?? Future.value('Terminal indisponível neste aparelho.');
    }
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
