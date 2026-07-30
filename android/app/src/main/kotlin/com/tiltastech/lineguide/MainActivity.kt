package com.tiltastech.castcircle

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register custom platform channel plugins
        flutterEngine.plugins.add(AndroidSttPlugin())
        flutterEngine.plugins.add(PdfTextPlugin())
        flutterEngine.plugins.add(ContactPickerPlugin())
        flutterEngine.plugins.add(MemoryMonitorPlugin())

        // Stub plugins for iOS-only features (graceful degradation)
        flutterEngine.plugins.add(KokoroMlxStubPlugin())
        flutterEngine.plugins.add(MlxSttStubPlugin())
        flutterEngine.plugins.add(MediaControlStubPlugin())
        flutterEngine.plugins.add(BackgroundDownloadStubPlugin())
    }
}
