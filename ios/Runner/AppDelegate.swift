import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var kokoroPlugin: KokoroMLXPlugin?
  private var mlxSttPlugin: MLXSttPlugin?
  private var downloadPlugin: BackgroundDownloadPlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    // URLSession background downloads call this when the download finishes
    // while the app is suspended. The completion handler must be called
    // after all delegate methods have been delivered.
    completionHandler()
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Register Kokoro-MLX platform channel
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "KokoroMLXPlugin") {
      kokoroPlugin = KokoroMLXPlugin(messenger: registrar.messenger())
    }

    // Register background download platform channel
    if let downloadRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "BackgroundDownloadPlugin") {
      downloadPlugin = BackgroundDownloadPlugin(messenger: downloadRegistrar.messenger())
    }

    // Register STT platform channel
    if let sttRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "MLXSttPlugin") {
      mlxSttPlugin = MLXSttPlugin(messenger: sttRegistrar.messenger())
    }
  }
}
