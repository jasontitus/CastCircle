import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // Hold strong references so the channel handlers outlive awakeFromNib.
  private var pdfTextPlugin: PdfTextPlugin?
  private var memoryMonitorPlugin: MemoryMonitorPlugin?
  private var downloadPlugin: BackgroundDownloadPlugin?
  private var visionOcrPlugin: VisionOcrPlugin?
  private var paddleOcrPlugin: PaddleOcrPlugin?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Register our manual native plugins here (not in the AppDelegate): this is
    // where the FlutterViewController is created and RegisterGeneratedPlugins
    // runs, so it works for both the normal app launch AND the integration-test
    // harness (where applicationDidFinishLaunching may register too late).
    let messenger = flutterViewController.engine.binaryMessenger
    pdfTextPlugin = PdfTextPlugin(messenger: messenger)
    memoryMonitorPlugin = MemoryMonitorPlugin(messenger: messenger)
    downloadPlugin = BackgroundDownloadPlugin(messenger: messenger)
    visionOcrPlugin = VisionOcrPlugin(messenger: messenger)

    // On-device PaddleOCR (shared cross-platform plugin) — same engine as iOS.
    // Needs a registrar (flutter-asset lookup of the ONNX models) + the messenger.
    let paddleRegistrar = flutterViewController.registrar(forPlugin: "PaddleOcrPlugin")
    paddleOcrPlugin = PaddleOcrPlugin(registrar: paddleRegistrar, messenger: messenger)

    super.awakeFromNib()
  }
}
