import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config/settings.dart';

/// Palavra de ativação ("acordar pela voz").
///
/// - Android: serviço nativo com Vosk offline, funciona com a tela apagada.
/// - iOS: a Siri acorda o app ("E aí Siri, falar com Assistente") por um atalho
///   do app; aqui só chega o aviso de que foi chamado.
/// - Desktop: não suportado.
class WakeService extends ChangeNotifier {
  WakeService(this.settings) {
    if (supported || Platform.isIOS) _ch.setMethodCallHandler(_onCall);
  }

  final AppSettings settings;
  static const _ch = MethodChannel('assistant/wake');

  /// Escuta com a tela apagada (só Android).
  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// Disparado quando o usuário chamou pelo nome (ou pela Siri).
  final _wakes = StreamController<void>.broadcast();
  Stream<void> get wakes => _wakes.stream;

  /// O que o reconhecedor ouviu no modo de teste.
  final _heard = StreamController<String>.broadcast();
  Stream<String> get heard => _heard.stream;

  bool running = false;
  bool modelReady = false;
  bool downloading = false;
  double progress = 0;
  String? error;
  List<String> unknownWords = const [];

  Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'wake':
        _wakes.add(null);
      case 'heard':
        _heard.add('${call.arguments}');
      case 'modelProgress':
        final a = (call.arguments as Map).cast<String, dynamic>();
        progress = (a['progress'] as num?)?.toDouble() ?? 0;
        error = a['error'] as String?;
        downloading = error == null && progress < 1;
        if (progress >= 1) {
          modelReady = true;
          await sync(); // modelo pronto: começa a escutar se estiver ligado
        }
        notifyListeners();
      case 'status':
        final a = (call.arguments as Map).cast<String, dynamic>();
        if (a.containsKey('error')) error = a['error'] as String?;
        if (a['listening'] == true) error = null;
        if (a['unknownWords'] is List) unknownWords = (a['unknownWords'] as List).cast<String>();
        notifyListeners();
    }
    return null;
  }

  Future<void> refresh() async {
    if (!supported) return;
    final s = (await _ch.invokeMapMethod<String, dynamic>('modelStatus')) ?? {};
    modelReady = s['ready'] == true;
    downloading = s['downloading'] == true;
    progress = (s['progress'] as num?)?.toDouble() ?? 0;
    running = await _ch.invokeMethod<bool>('isRunning') ?? false;
    notifyListeners();
  }

  /// Liga/desliga o serviço conforme as configurações. Com a rede entre
  /// aparelhos ligada, o serviço fica vivo mesmo sem escutar o nome, para
  /// receber pedidos com o app fechado.
  Future<void> sync() async {
    if (!supported) return;
    final listen = settings.wakeWordEnabled && modelReady;
    if (listen || (settings.meshEnabled && settings.meshCode.isNotEmpty)) {
      try {
        await _ch.invokeMethod('start', {'phrases': settings.wakePhrases, 'listen': listen, 'high': settings.wakeHighSensitivity});
        running = true;
      } on PlatformException catch (e) {
        error = 'Não consegui iniciar a escuta: ${e.message}';
      }
    } else {
      await _ch.invokeMethod('stop');
      running = false;
    }
    notifyListeners();
  }

  Future<void> downloadModel() async {
    if (!supported) return;
    downloading = true;
    error = null;
    notifyListeners();
    await _ch.invokeMethod('downloadModel');
  }

  /// Solta o microfone (uma conversa vai começar).
  Future<void> pause() async {
    if (supported) await _ch.invokeMethod('pause');
  }

  /// Volta a esperar o nome.
  Future<void> resume() async {
    if (supported) await _ch.invokeMethod('resume');
  }

  Future<void> setTest(bool on) async {
    if (supported) await _ch.invokeMethod('test', {'on': on});
  }

  /// Abre o modo assistente por cima de tudo (acende a tela), como se o
  /// usuário tivesse chamado pelo nome. Chega de volta como evento [wakes].
  Future<void> openAssistant() async {
    if (supported) await _ch.invokeMethod('openAssistant');
  }

  /// Fim da conversa do modo assistente: volta para a tela anterior/bloqueio.
  Future<void> finishWake() async {
    if (supported) await _ch.invokeMethod('finishWake');
  }

  Future<bool> canDrawOverlays() async => supported && (await _ch.invokeMethod<bool>('canDrawOverlays') ?? false);
  Future<void> requestOverlay() => _ch.invokeMethod('requestOverlay');
  Future<bool> isIgnoringBattery() async => supported && (await _ch.invokeMethod<bool>('isIgnoringBattery') ?? false);
  Future<void> requestBattery() => _ch.invokeMethod('requestBattery');

  /// iOS: o app foi aberto pela Siri antes do Dart estar pronto?
  Future<bool> takePendingIosWake() async {
    if (!Platform.isIOS) return false;
    try {
      return await _ch.invokeMethod<bool>('takePendingWake') ?? false;
    } on MissingPluginException {
      return false;
    }
  }
}
