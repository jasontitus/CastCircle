import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var kokoroPlugin: KokoroMLXPlugin?
  private var mlxSttPlugin: MLXSttPlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Register Kokoro-MLX platform channel
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "KokoroMLXPlugin") {
      kokoroPlugin = KokoroMLXPlugin(messenger: registrar.messenger())
    }

    // Register MLX STT platform channel
    if let controller = window?.rootViewController as? FlutterViewController {
      mlxSttPlugin = MLXSttPlugin(messenger: controller.binaryMessenger)
    }
  }
}
