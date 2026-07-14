import AVFoundation
import AVKit
import MPVKitSampleBufferGPL
import SwiftUI

#if arch(arm64)
private let defaultMacVideoURL = URL(
    string: "https://github.com/mpvkit/video-test/raw/master/resources/HDR10_ToneMapping_Test_240_1000_nits.mp4"
)!
#endif

struct ContentView: View {
    #if arch(arm64)
    @StateObject private var player = MacGPUPlayerView.Coordinator()
    #endif

    var body: some View {
        #if arch(arm64)
        ZStack {
            MacGPUPlayerView(coordinator: player)
                .play(defaultMacVideoURL)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack {
                    Text(player.status)
                        .font(.caption)
                    Spacer()
                    Text(player.backend)
                        .font(.caption)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.65))
                )

                Spacer()

                HStack {
                    Button(player.isPaused ? "Play" : "Pause") {
                        player.setPlaying(player.isPaused)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    Button("-10") { player.seek(by: -10) }
                    Button("+10") { player.seek(by: 10) }
                    Button(player.isPictureInPictureActive ? "End PiP" : "PiP") {
                        player.togglePictureInPicture()
                    }
                    .disabled(!player.isPictureInPictureSupported)
                    Button("HDR") { player.play(defaultMacVideoURL) }
                    Button("H.264") {
                        player.play(URL(string: "https://vjs.zencdn.net/v/oceans.mp4")!)
                    }
                }
                .buttonStyle(DefaultButtonStyle())
            }
            .padding()

            if player.isLoading {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .preferredColorScheme(.dark)
        .onDisappear { player.stop() }
        #else
        VStack(spacing: 12) {
            Text("The native macOS GPU renderer is Apple Silicon only.")
                .font(.title2)
            Text("Build this demo for arm64. Intel remains outside the GPU-PiP release target.")
                .foregroundColor(.secondary)
        }
        .frame(minWidth: 640, minHeight: 360)
        #endif
    }
}

#if arch(arm64)
private struct MacGPUPlayerView: NSViewRepresentable {
    @ObservedObject var coordinator: Coordinator

    func makeCoordinator() -> Coordinator { coordinator }

    func makeNSView(context: Context) -> MacGPUPlayerHostView {
        let view = MacGPUPlayerHostView()
        view.onLayout = { [weak coordinator] bounds, scale in
            coordinator?.updateInlineLayout(bounds: bounds, scale: scale)
        }
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: MacGPUPlayerHostView, context: Context) {
        context.coordinator.updateInlineLayout(
            bounds: view.bounds,
            scale: view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        )
    }

    func play(_ url: URL) -> Self {
        coordinator.pendingURL = url
        return self
    }

    @MainActor
    final class Coordinator: NSObject, ObservableObject {
        @Published private(set) var isPaused = true
        @Published private(set) var isLoading = true
        @Published private(set) var isPictureInPictureActive = false
        @Published private(set) var status = "Starting AppKit shared-GPU renderer"
        @Published private(set) var backend = "PiP: automatic"

        var pendingURL: URL?
        var isPictureInPictureSupported: Bool {
            guard #available(macOS 12.0, *) else { return false }
            return AVPictureInPictureController.isPictureInPictureSupported()
        }

        private var renderer: MPVGPUPlayerRenderer?
        private var pictureInPictureController: AVPictureInPictureController?
        private var pictureInPictureTask: Task<Void, Never>?
        private var pictureInPictureRequestGeneration: UInt64 = 0

        func attach(to view: MacGPUPlayerHostView) {
            guard renderer == nil else { return }
            let options = MPVGPUPlayerRendererOptions(
                maximumPiPFrameSize: CGSize(width: 1920, height: 1080),
                enablesTargetColorspaceHint: true,
                pictureInPictureBackendPreference: .automatic,
                maximumInFlightPictureInPictureFrames: 3,
                pictureInPicturePreparationTimeout: 1,
                maximumInlineDrawablePixelCount: 14_745_600,
                inlineResizeDebounceInterval: 1.0 / 30.0
            )
            // Exercise MPVKit's real AppKit adapter rather than treating the Mac like UIKit.
            let renderer = MPVGPUPlayerRenderer(view: view, options: options)
            renderer.onStateChange = { [weak self] state in
                self?.handleRendererState(state)
            }
            renderer.onPictureInPictureStateChange = { [weak self] state in
                self?.status = Self.describe(state)
            }
            renderer.onDiagnostics = { [weak self] diagnostics in
                if let selected = diagnostics.selectedPictureInPictureBackend {
                    self?.backend = "PiP: \(selected.rawValue)"
                }
            }
            renderer.onPictureInPictureStopRequested = { [weak self, weak renderer] reason in
                guard let self, let renderer else { return }
                self.status = "PiP ending: \(reason)"
                if self.pictureInPictureController?.isPictureInPictureActive == true {
                    self.pictureInPictureController?.stopPictureInPicture()
                } else {
                    renderer.endPictureInPicture(restoringInlinePlayback: true)
                }
            }
            renderer.onError = { [weak self] error in self?.status = error }

            do {
                try renderer.start()
                self.renderer = renderer
                configurePictureInPicture(for: renderer)
                if let pendingURL { play(pendingURL) }
            } catch {
                status = "Start failed: \(error.localizedDescription)"
                isLoading = false
            }
        }

        func updateInlineLayout(bounds: CGRect, scale: CGFloat) {
            renderer?.updateInlineLayerLayout(bounds: bounds, contentsScale: scale)
        }

        func play(_ url: URL) {
            pendingURL = url
            pictureInPictureRequestGeneration &+= 1
            pictureInPictureTask?.cancel()
            renderer?.load(url)
            renderer?.play()
            isPaused = false
            isLoading = true
            invalidatePictureInPicturePlaybackState()
        }

        func setPlaying(_ playing: Bool) {
            guard let renderer else { return }
            if playing { renderer.play() } else { renderer.pause() }
            isPaused = !playing
            finishTimelineUpdate(using: renderer)
        }

        func seek(by interval: Double) {
            guard let renderer else { return }
            renderer.seek(by: interval)
            finishTimelineUpdate(using: renderer)
        }

        func togglePictureInPicture() {
            guard #available(macOS 12.0, *), let controller = pictureInPictureController else {
                status = "Custom PiP requires macOS 12 and AVKit support"
                return
            }
            pictureInPictureRequestGeneration &+= 1
            let generation = pictureInPictureRequestGeneration
            pictureInPictureTask?.cancel()
            if controller.isPictureInPictureActive {
                controller.stopPictureInPicture()
                return
            }

            guard let renderer else { return }
            pictureInPictureTask = Task { @MainActor [weak self, weak controller] in
                guard let self, let controller else { return }
                do {
                    try await renderer.preparePictureInPicture()
                } catch {
                    guard generation == self.pictureInPictureRequestGeneration,
                          !Task.isCancelled else { return }
                    self.status = "PiP preparation failed: \(error.localizedDescription)"
                    return
                }
                guard generation == self.pictureInPictureRequestGeneration,
                      !Task.isCancelled else { return }
                controller.invalidatePlaybackState()
                guard controller.isPictureInPicturePossible else {
                    self.status = "AVKit reports PiP is not currently possible"
                    renderer.endPictureInPicture(restoringInlinePlayback: true)
                    return
                }
                controller.startPictureInPicture()
            }
        }

        func stop() {
            pictureInPictureRequestGeneration &+= 1
            pictureInPictureTask?.cancel()
            pictureInPictureTask = nil
            pictureInPictureController?.stopPictureInPicture()
            guard let renderer else { return }
            renderer.stop()
            Task { await renderer.waitUntilStopped() }
            self.renderer = nil
        }

        private func finishTimelineUpdate(using renderer: MPVGPUPlayerRenderer, completion: (() -> Void)? = nil) {
            Task { @MainActor [weak self] in
                await renderer.waitForPictureInPictureTimelineUpdate()
                self?.invalidatePictureInPicturePlaybackState()
                completion?()
            }
        }

        private func configurePictureInPicture(for renderer: MPVGPUPlayerRenderer) {
            guard #available(macOS 12.0, *), isPictureInPictureSupported else { return }
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: renderer.pictureInPictureDisplayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.requiresLinearPlayback = false
            pictureInPictureController = controller
        }

        private func handleRendererState(_ state: MPVGPUPlayerRendererState) {
            switch state {
            case .starting, .loading:
                isLoading = true
            case .playing:
                isLoading = false
                isPaused = false
            case .paused:
                isLoading = false
                isPaused = true
            case .pictureInPicture:
                isLoading = false
            case .failed(let reason):
                isLoading = false
                status = reason
            default:
                isLoading = false
            }
            invalidatePictureInPicturePlaybackState()
        }

        private func invalidatePictureInPicturePlaybackState() {
            if #available(macOS 12.0, *) {
                pictureInPictureController?.invalidatePlaybackState()
            }
        }

        private static func describe(_ state: MPVPictureInPictureState) -> String {
            switch state {
            case .idle: return "PiP idle"
            case .preparing: return "Preparing current-generation PiP frame"
            case .ready: return "PiP ready"
            case .active: return "PiP active"
            case .restoring: return "Restoring inline GPU output"
            case .failed(_, let reason): return "PiP failed: \(reason)"
            }
        }
    }
}

@available(macOS 12.0, *)
extension MacGPUPlayerView.Coordinator: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate, @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        renderer?.beginPictureInPicture()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isPictureInPictureActive = true
        status = "PiP active"
        controller.invalidatePlaybackState()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isPictureInPictureActive = false
        renderer?.endPictureInPicture(restoringInlinePlayback: true)
        controller.invalidatePlaybackState()
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isPictureInPictureActive = false
        status = "AVKit PiP failed: \(error.localizedDescription)"
        renderer?.endPictureInPicture(restoringInlinePlayback: true)
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        guard let renderer else {
            completionHandler(false)
            return
        }
        Task { @MainActor [weak self, weak controller] in
            let restored = await renderer.endPictureInPictureAndWait(restoringInlinePlayback: true)
            guard let self, self.renderer === renderer else {
                completionHandler(false)
                return
            }
            controller?.invalidatePlaybackState()
            completionHandler(restored)
        }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        setPlaying(playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        let rawPosition = renderer?.currentTime ?? 0
        let position = rawPosition.isFinite ? max(0, rawPosition) : 0
        let rawDuration = renderer?.duration ?? 0
        let duration = rawDuration.isFinite && rawDuration > 0
            ? max(rawDuration, position + 1)
            : max(600, position + 600)
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        isPaused
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        renderer?.updatePictureInPictureRenderSize(
            CGSize(width: Int(newRenderSize.width), height: Int(newRenderSize.height))
        )
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        guard let renderer else {
            completionHandler()
            return
        }
        renderer.seek(by: skipInterval.seconds)
        finishTimelineUpdate(using: renderer, completion: completionHandler)
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ controller: AVPictureInPictureController) -> Bool {
        false
    }
}

private final class MacGPUPlayerHostView: NSView {
    let metalLayer = MPVGPUPlayerMetalLayer()
    var onLayout: ((CGRect, CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = metalLayer
        metalLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = metalLayer
        metalLayer.backgroundColor = NSColor.black.cgColor
    }

    override func layout() {
        super.layout()
        onLayout?(bounds, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onLayout?(bounds, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
    }
}
#endif
