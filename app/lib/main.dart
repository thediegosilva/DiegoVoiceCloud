import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import 'config/settings.dart';
import 'services/gemini_live_session.dart';
import 'services/livekit_session.dart';
import 'services/chat_store.dart';
import 'services/mem0_service.dart';
import 'services/mesh/mesh_service.dart';
import 'services/mesh/remote_task_runner.dart';
import 'services/pc_control.dart';
import 'services/terminal_service.dart';
import 'services/tool_registry.dart';
import 'services/voice_session.dart';
import 'services/voicemonkey_service.dart';
import 'services/wake_service.dart';
import 'ui/assistant_screen.dart';
import 'ui/orb.dart';
import 'ui/session_screen.dart';
import 'ui/api_keys_card.dart';
import 'ui/backdrop.dart';
import 'ui/chat_history.dart';
import 'ui/copyright_footer.dart';
import 'ui/onboarding_screen.dart';
import 'ui/settings_screen.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  final services = AppServices(settings);
  runApp(AssistantApp(services: services));
  unawaited(services.init());
}

/// Serviços que vivem o tempo todo (fora das conversas): rede entre
/// aparelhos e palavra de ativação.
class AppServices {
  AppServices(this.settings, {ChatStore? chats})
      : mesh = MeshService(settings),
        wake = WakeService(settings),
        chats = chats ?? ChatStore();

  final AppSettings settings;
  final MeshService mesh;
  final WakeService wake;

  /// Histórico de conversas (só neste aparelho).
  final ChatStore chats;

  /// Conversa aberta agora (só uma por vez).
  VoiceSession? active;

  Future<void> init() async {
    // Tarefas vindas de outros aparelhos rodam por texto, sem abrir conversa.
    final pc = PcControl(confirm: confirmDialog);
    await pc.init();
    final remoteTools = ToolRegistry(
      voiceMonkey: VoiceMonkeyService(settings.voiceMonkeyToken),
      pc: pc,
      pcEnabled: settings.pcToolsEnabled,
      // Pedido remoto nunca roda comando sem confirmação na tela.
      terminal: TerminalService.supported
          ? TerminalService(
              mode: () => settings.terminalMode == TerminalMode.off ? TerminalMode.off : TerminalMode.ask,
              confirm: (q) => confirmDialog('Pedido vindo de outro aparelho:\n\n$q'))
          : null,
      mesh: mesh,
    );
    final runner = RemoteTaskRunner(settings: settings, tools: remoteTools, mesh: mesh);
    mesh.onTask = runner.run;

    await chats.load();
    await wake.refresh();
    await syncBackground();
  }

  /// Aplica as configurações da rede e da escuta (chame quando mudarem).
  Future<void> syncBackground() async {
    await mesh.sync();
    // Não religa a escuta no meio de uma conversa (ela segura o microfone).
    if (active == null) await wake.sync();
  }

  Future<VoiceSession> buildSession({bool assistant = false, String? greeting, List<ChatMessage> history = const []}) async {
    if (Platform.isAndroid || Platform.isIOS) {
      await [
        Permission.microphone,
        if (!assistant) Permission.camera,
        // Para achar e usar o fone Bluetooth (microfone e som) na conversa.
        if (Platform.isAndroid) Permission.bluetoothConnect,
      ].request();
    }
    if (settings.mode == ConnectionMode.livekit) return LiveKitSession(settings: settings, history: history);
    final pc = PcControl(confirm: confirmDialog);
    await pc.init();
    final tools = ToolRegistry(
      voiceMonkey: VoiceMonkeyService(settings.voiceMonkeyToken),
      pc: pc,
      pcEnabled: settings.pcToolsEnabled,
      terminal: TerminalService.supported ? TerminalService(mode: () => settings.terminalMode, confirm: confirmDialog) : null,
      mesh: settings.meshEnabled ? mesh : null,
    );
    final session = GeminiLiveSession(
      settings: settings,
      mem0: Mem0Service(settings.mem0ApiKey),
      tools: tools,
      history: history,
      greeting: greeting ??
          (assistant
              ? 'Você acabou de ser chamada pelo nome. Responda só com algo bem curto, como "Pois não?" ou "Oi, pode falar."'
              : history.isNotEmpty
                  ? 'O usuário reabriu esta conversa para continuar. Diga só algo curto, como "Vamos continuar de onde paramos?"'
                  : null),
    );
    if (assistant) tools.onEndConversation = () => session.disconnect();
    return session;
  }

  /// Diálogo de confirmação usado pelas ferramentas destrutivas do PC.
  static Future<bool> confirmDialog(String pergunta) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return false;
    final ok = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: const Text('A IA pede confirmação'),
        content: Text(pergunta),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Confirmar')),
        ],
      ),
    );
    return ok ?? false;
  }
}

class AssistantApp extends StatelessWidget {
  const AssistantApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final dark = ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1FD5F9), brightness: Brightness.dark),
      scaffoldBackgroundColor: const Color(0xFF070B14),
    );
    return MaterialApp(
      title: 'Assistente',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF002CF2))),
      darkTheme: dark,
      themeMode: ThemeMode.dark,
      locale: const Locale('pt', 'BR'),
      supportedLocales: const [Locale('pt', 'BR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: _Root(services: services),
    );
  }
}

/// Primeira abertura: perguntas de boas-vindas. Depois: tela inicial.
class _Root extends StatelessWidget {
  const _Root({required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: services.settings,
        builder: (_, _) => services.settings.onboardingDone
            ? HomeScreen(services: services)
            : OnboardingScreen(settings: services.settings, onDone: () {}),
      );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.services});

  final AppServices services;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppServices get services => widget.services;
  AppSettings get settings => services.settings;

  StreamSubscription? _wakeSub;
  StreamSubscription<MeshMessage>? _meshSub;

  @override
  void initState() {
    super.initState();
    _wakeSub = services.wake.wakes.listen((_) => _startAssistant());
    _meshSub = services.mesh.incoming.listen(_onMesh);
    // iOS: aberto pela Siri antes do app estar pronto.
    services.wake.takePendingIosWake().then((p) {
      if (p) _startAssistant();
    });
  }

  @override
  void dispose() {
    _wakeSub?.cancel();
    _meshSub?.cancel();
    super.dispose();
  }

  /// Recado ou resposta chegou e não há conversa aberta: abre o assistente
  /// para falar em voz alta (no Android, acende a tela).
  void _onMesh(MeshMessage m) {
    if (services.active != null) return; // a conversa aberta já avisa
    final String? greeting = switch (m.kind) {
      MeshKind.note => 'Chegou um recado do aparelho "${m.from}" do usuário: "${m.text}". '
          'Diga o recado ao usuário agora, de forma natural e breve.',
      MeshKind.reply => 'Chegou a resposta do aparelho "${m.from}": "${m.text}". Conte ao usuário em uma frase.',
      _ => null,
    };
    if (greeting == null) return;
    if (!settings.meshSpeakNotes) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('📨 ${m.from}: ${m.text}')));
      return;
    }
    _pendingGreeting = greeting;
    if (WakeService.supported) {
      services.wake.openAssistant(); // volta como evento "wake"
    } else {
      _startAssistant();
    }
  }

  String? _pendingGreeting;
  bool _assistantOpen = false;

  /// Modo assistente (estilo Siri), aberto pela voz, pela Siri ou por recado.
  Future<void> _startAssistant() async {
    if (_assistantOpen) return;
    if (services.active != null) {
      // Já tem conversa aberta: só volta para ela.
      await services.wake.finishWake();
      return;
    }
    _assistantOpen = true;
    final greeting = _pendingGreeting;
    _pendingGreeting = null;
    await services.wake.pause();
    final session = await services.buildSession(assistant: true, greeting: greeting);
    final recorder = ChatRecorder(services.chats, session, ChatStore.newId());
    services.active = session;
    final nav = navigatorKey.currentState;
    if (nav != null) {
      nav.popUntil((r) => r.isFirst);
      await nav.push(PageRouteBuilder(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, _, _) => AssistantScreen(
          session: session,
          name: settings.assistantName,
          idleSeconds: settings.wakeIdleSeconds,
        ),
        transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
      ));
    }
    if (session.state != SessionState.idle) await session.disconnect();
    await recorder.close();
    session.dispose();
    services.active = null;
    _assistantOpen = false;
    await services.wake.finishWake();
    await services.wake.resume();
  }

  /// Abre uma conversa: nova, ou continuando uma salva ([chat]).
  Future<void> _start(BuildContext context, {ChatSummary? chat}) async {
    await services.wake.pause();
    final history = chat == null ? const <ChatMessage>[] : await services.chats.messages(chat.id);
    final session = await services.buildSession(history: history);
    services.active = session;
    final recorder = ChatRecorder(services.chats, session, chat?.id ?? ChatStore.newId());
    if (!context.mounted) {
      await recorder.close();
      session.dispose();
      services.active = null;
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SessionScreen(
        session: session,
        title: '${settings.assistantName} · ${settings.mode == ConnectionMode.livekit ? 'LiveKit' : 'Modelo de IA'}',
        femaleVoice: settings.voiceIsFemale,
      ),
    ));
    if (session.state != SessionState.idle) await session.disconnect();
    await recorder.close();
    session.dispose();
    services.active = null;
    await services.wake.resume();
  }

  /// Abre uma conversa salva para ler (e, se quiser, continuar).
  Future<void> _openChat(BuildContext context, ChatSummary chat) async {
    final cont = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => ChatViewScreen(store: services.chats, chatId: chat.id),
    ));
    if (cont == true && context.mounted) {
      final c = services.chats.byId(chat.id);
      if (c != null) await _start(context, chat: c);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        // Histórico de conversas na lateral (como no ChatGPT).
        drawer: ChatHistoryDrawer(
          store: services.chats,
          onOpen: (chat) => _openChat(context, chat),
          onNew: () => _start(context),
        ),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          leading: Builder(
            builder: (ctx) => IconButton(
              tooltip: 'Conversas',
              icon: const Icon(Icons.menu_rounded),
              onPressed: () => Scaffold.of(ctx).openDrawer(),
            ),
          ),
          title: Text(
              RegExp(r'^[A-Za-z]{2,8}$').hasMatch(settings.assistantName)
                  ? '${settings.assistantName.toUpperCase().split('').join('.')}.'
                  : settings.assistantName.toUpperCase(),
              style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 3)),
          actions: [
            IconButton(
              tooltip: 'Configurações',
              icon: const Icon(Icons.tune_rounded),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsScreen(services: services))),
            ),
          ],
        ),
        body: AuroraBackdrop(
          palette: settings.voiceIsFemale ? OrbPalette.female : OrbPalette.male,
          intensity: 0.5,
          child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AssistantOrb(state: SessionState.listening, level: 0.08, female: settings.voiceIsFemale, size: 210),
                  const SizedBox(height: 24),
                  SegmentedButton<ConnectionMode>(
                    segments: const [
                      ButtonSegment(value: ConnectionMode.livekit, label: Text('LiveKit + PC'), icon: Icon(Icons.dns)),
                      ButtonSegment(value: ConnectionMode.gemini, label: Text('Modelo de IA'), icon: Icon(Icons.bolt)),
                    ],
                    selected: {settings.mode},
                    onSelectionChanged: (v) => settings.mode = v.first,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    settings.mode == ConnectionMode.livekit
                        ? 'Conecta ao agente Python rodando no seu PC (backend/). Controle do PC, casa e memória rodam lá.'
                        : 'Fala direto com o Modelo de IA, sem servidor. Casa e memória rodam no app'
                            '${PcControl.supported ? '; controle do PC também (este é um desktop).' : '. Controle do PC só no app desktop.'}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (settings.mode == ConnectionMode.gemini) ...[
                    const SizedBox(height: 16),
                    settings.geminiKeys.isEmpty
                        ? TextButton.icon(
                            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsScreen(services: services))),
                            icon: const Icon(Icons.vpn_key_rounded, size: 16),
                            label: const Text('Adicionar chave da API'),
                          )
                        : ApiKeyPicker(settings: settings),
                  ],
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(240, 58),
                      backgroundColor: (settings.voiceIsFemale ? OrbPalette.female : OrbPalette.male).primary,
                      foregroundColor: Colors.white,
                      elevation: 4,
                      shadowColor: (settings.voiceIsFemale ? OrbPalette.female : OrbPalette.male).primary.withValues(alpha: 0.35),
                      textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0.4),
                    ),
                    onPressed: () => _start(context),
                    icon: const Icon(Icons.mic),
                    label: const Text('Iniciar chamada'),
                  ),
                  const SizedBox(height: 40),
                  const CopyrightFooter(),
                ],
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }
}
