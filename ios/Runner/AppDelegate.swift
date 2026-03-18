import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var kokoroPlugin: KokoroMLXPlugin?
  private var mlxSttPlugin: MLXSttPlugin?
  private var appleSttPlugin: AppleSttPlugin?
  private var downloadPlugin: BackgroundDownloadPlugin?
  private var memoryMonitorPlugin: MemoryMonitorPlugin?
  private var mediaControlPlugin: MediaControlPlugin?
  private var pdfTextPlugin: PdfTextPlugin?
  private var contactPickerPlugin: ContactPickerPlugin?

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

    // Register STT platform channels
    if let sttRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "MLXSttPlugin") {
      mlxSttPlugin = MLXSttPlugin(messenger: sttRegistrar.messenger())
    }
    if let appleSttRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppleSttPlugin") {
      appleSttPlugin = AppleSttPlugin(messenger: appleSttRegistrar.messenger())
    }

    // Register memory monitor
    if let memRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "MemoryMonitorPlugin") {
      memoryMonitorPlugin = MemoryMonitorPlugin(messenger: memRegistrar.messenger())
    }

    // Register media control (AirPods / lock screen remote commands)
    if let mediaRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "MediaControlPlugin") {
      mediaControlPlugin = MediaControlPlugin(messenger: mediaRegistrar.messenger())
    }

    // Register PDF text extraction (PDFKit fallback for complex PDF layouts)
    if let pdfRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "PdfTextPlugin") {
      pdfTextPlugin = PdfTextPlugin(messenger: pdfRegistrar.messenger())
    }

    // Register contact picker
    if let contactRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "ContactPickerPlugin") {
      contactPickerPlugin = ContactPickerPlugin(messenger: contactRegistrar.messenger())
    }
  }
}
