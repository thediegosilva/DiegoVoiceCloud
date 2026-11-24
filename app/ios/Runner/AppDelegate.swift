import AppIntents
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AssistantWakeBridge") {
      WakeBridge.shared.attach(messenger: registrar.messenger())
    }
  }
}

/// Avisa o Dart que o usuário chamou a IA pela Siri (canal "assistant/wake").
final class WakeBridge {
  static let shared = WakeBridge()

  private var channel: FlutterMethodChannel?
  /// Chamado antes do Dart estar pronto (app aberto do zero pela Siri).
  private var pending = false

  func attach(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "assistant/wake", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      if call.method == "takePendingWake" {
        let p = self?.pending ?? false
        self?.pending = false
        result(p)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }

  func trigger() {
    pending = true
    // Se o Dart já está rodando, ele recebe na hora (e limpa o pendente).
    channel?.invokeMethod("wake", arguments: nil) { [weak self] _ in self?.pending = false }
  }
}

// MARK: - Siri / Atalhos
//
// "E aí Siri, falar com Assistente" abre o app direto no modo assistente.
// O nome falado para a Siri é o nome do app (Assistente). Para usar o nome da
// IA (ex.: Lexy ou Diego), crie um atalho no app Atalhos com a ação "Chamar a
// IA" e dê a ele esse nome — "E aí Siri, Lexy".

@available(iOS 16.0, *)
struct ChamarIAIntent: AppIntent {
  static let title: LocalizedStringResource = "Chamar a IA"
  static let openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    WakeBridge.shared.trigger()
    return .result()
  }
}

@available(iOS 16.0, *)
struct AssistantShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ChamarIAIntent(),
      phrases: [
        "Falar com \(.applicationName)",
        "Chamar \(.applicationName)",
        "Acordar \(.applicationName)",
        "Abrir assistente \(.applicationName)",
      ]
    )
  }
}
