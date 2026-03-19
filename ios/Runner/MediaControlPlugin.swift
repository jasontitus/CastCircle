import Flutter
import MediaPlayer

/// Registers for MPRemoteCommandCenter events (AirPods controls, lock screen,
/// Action Button when configured as media control) and forwards them to Flutter.
///
/// Mappings:
///   - Previous track (double-tap left AirPod) → "jumpBack"
///   - Play/Pause toggle                       → "playPause"
///   - Next track (double-tap right AirPod)    → "skip"
class MediaControlPlugin: NSObject {
    private let channel: FlutterMethodChannel
    private var isActive = false

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.lineguide/media_controls",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler(handle)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "activate":
            activate()
            result(true)
        case "deactivate":
            deactivate()
            result(true)
        case "updateNowPlaying":
            let args = call.arguments as? [String: Any] ?? [:]
            let title = args["title"] as? String ?? "Rehearsal"
            let character = args["character"] as? String ?? ""
            updateNowPlaying(title: title, character: character)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func activate() {
        guard !isActive else { return }
        isActive = true

        let center = MPRemoteCommandCenter.shared()

        // Previous track → jump back (double-tap left AirPod)
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.channel.invokeMethod("onMediaCommand", arguments: "jumpBack")
            return .success
        }

        // Next track → ALSO jump back (double-tap right AirPod)
        // Users only need "go back and try again" — no use case for skipping ahead
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.channel.invokeMethod("onMediaCommand", arguments: "jumpBack")
            return .success
        }

        // Play/pause → toggle pause
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.channel.invokeMethod("onMediaCommand", arguments: "playPause")
            return .success
        }

        // Also handle discrete play and pause commands (some headphones send these
        // instead of togglePlayPause)
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.channel.invokeMethod("onMediaCommand", arguments: "playPause")
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.channel.invokeMethod("onMediaCommand", arguments: "playPause")
            return .success
        }

        // Set initial now-playing info so the system knows we're an active media app
        updateNowPlaying(title: "CastCircle", character: "Rehearsal")

        NSLog("MediaControl: activated remote commands")
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false

        let center = MPRemoteCommandCenter.shared()
        center.previousTrackCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        NSLog("MediaControl: deactivated remote commands")
    }

    private func updateNowPlaying(title: String, character: String) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: character,
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        // Setting a non-zero playback rate tells the system we're actively playing,
        // which keeps the remote command targets responsive.
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
