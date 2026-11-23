import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import 'config/settings.dart';
import 'services/gemini_live_session.dart';
import 'services/livekit_session.dart';
import 'services/mem0_service.dart';
import 'services/pc_control.dart';
import 'services/tool_registry.dart';
import 'services/voice_session.dart';
import 'services/voicemonkey_service.dart';
import 'ui/orb.dart';
import 'ui/session_screen.dart';
import 'ui/api_keys_card.dart';
import 'ui/backdrop.dart';
import 'ui/settings_screen.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  runApp(JarvisApp(settings: settings));
}

class JarvisApp extends StatelessWidget {
  const JarvisApp({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final dark = ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1FD5F9), brightness: Brightness.dark),
      scaffoldBackgroundColor: const Color(0xFF070B14),
    );
    return MaterialApp(
      title: 'Jarvis',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF002CF2))),
      darkTheme: dark,
      themeMode: ThemeMode.dark,
      home: HomeScreen(settings: settings),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.settings});

  final AppSettings settings;

  /// Diálogo de confirmação usado pelas ferramentas destrutivas do PC.
  static Future<bool> _confirm(String pergunta) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return false;
    final ok = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: const Text('Jarvis pede confirmação'),
        content: Text(pergunta),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Confirmar')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _start(BuildContext context) async {
    if (Platform.isAndroid || Platform.isIOS) {
      await [Permission.microphone, if (settings.mode == JarvisMode.livekit) Permission.camera].request();
    }

    final VoiceSession session;
    if (settings.mode == JarvisMode.livekit) {
      session = LiveKitSession(settings: settings);
    } else {
      final pc = PcControl(confirm: _confirm);
      await pc.init();
      session = GeminiLiveSession(
        settings: settings,
        mem0: Mem0Service(settings.mem0ApiKey),
        tools: ToolRegistry(
          voiceMonkey: VoiceMonkeyService(settings.voiceMonkeyToken),
          pc: pc,
          pcEnabled: settings.pcToolsEnabled,
        ),
      );
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SessionScreen(
        session: session,
        title: settings.mode == JarvisMode.livekit ? 'Jarvis · LiveKit' : 'Jarvis · Gemini',
        femaleVoice: settings.voiceIsFemale,
      ),
    ));
    if (session.state != SessionState.idle) await session.disconnect();
    session.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          title: const Text('J.A.R.V.I.S.', style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 3)),
          actions: [
            IconButton(
              tooltip: 'Configurações',
              icon: const Icon(Icons.tune_rounded),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsScreen(settings: settings))),
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
                  JarvisOrb(state: SessionState.listening, level: 0.08, female: settings.voiceIsFemale, size: 210),
                  const SizedBox(height: 24),
                  SegmentedButton<JarvisMode>(
                    segments: const [
                      ButtonSegment(value: JarvisMode.livekit, label: Text('LiveKit + PC'), icon: Icon(Icons.dns)),
                      ButtonSegment(value: JarvisMode.gemini, label: Text('Gemini direto'), icon: Icon(Icons.bolt)),
                    ],
                    selected: {settings.mode},
                    onSelectionChanged: (v) => settings.mode = v.first,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    settings.mode == JarvisMode.livekit
                        ? 'Conecta ao agente Python rodando no seu PC (backend/). Controle do PC, casa e memória rodam lá.'
                        : 'Fala direto com o Gemini, sem servidor. Casa e memória rodam no app'
                            '${PcControl.supported ? '; controle do PC também (este é um desktop).' : '. Controle do PC só no app desktop.'}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (settings.mode == JarvisMode.gemini) ...[
                    const SizedBox(height: 16),
                    settings.geminiKeys.isEmpty
                        ? TextButton.icon(
                            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsScreen(settings: settings))),
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
                      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0.4),
                    ),
                    onPressed: () => _start(context),
                    icon: const Icon(Icons.mic),
                    label: const Text('Iniciar chamada'),
                  ),
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
