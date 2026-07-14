import AVFoundation
import AVKit
import MPVKitSampleBufferGPL
import SwiftUI
import UIKit

private let defaultTVVideoURL = URL(
    string: "https://github.com/mpvkit/video-test/raw/master/resources/HDR10_ToneMapping_Test_240_1000_nits.mp4"
)!

struct ContentView: View {
    @StateObject private var player = TVGPUPlayerView.Coordinator()

    var body: some View {
        ZStack {
            TVGPUPlayerView(coordinator: player)
                .play(defaultTVVideoURL)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(player.status)
                        .font(.caption.monospaced())
                    Spacer()
                    Text(player.backend)
                        .font(.caption.monospaced())
                }
                .padding()
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))

                Spacer()

                HStack(spacing: 24) {
                    Button(player.isPaused ? "Play" : "Pause") {
                        player.setPlaying(player.isPaused)
                    }
                    Button("Back 10") { player.seek(by: -10) }
                    Button("Forward 10") { player.seek(by: 10) }
                    Button(player.isPictureInPictureActive ? "End PiP" : "Start PiP") {
                        player.togglePictureInPicture()
                    }
                    .disabled(!player.isPictureInPictureSupported)
                    Button("HDR") {
                        player.play(defaultTVVideoURL)
                    }
                    Button("H.264") {
                        player.play(URL(string: "https://vjs.zencdn.net/v/oceans.mp4")!)
                    }
                }
            }
            .padding(55)

            if player.isLoading {
                ProgressView()
                    .scaleEffect(1.5)
            }
        }
        // Remote commands use the same ordered renderer -> timebase -> AVKit path as PiP controls.
        .onPlayPauseCommand { player.setPlaying(player.isPaused) }
        .onMoveCommand { direction in
            switch direction {
            case .left: player.seek(by: -10)
            case .right: player.seek(by: 10)
            default: break
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { player.stop() }
    }
}

private struct TVGPUPlayerView: UIViewRepresentable {
    @ObservedObject var coordinator: Coordinator

    func makeCoordinator() -> Coordinator { coordinator }

    func makeUIView(context: Context) -> TVGPUPlayerHostView {
        let view = TVGPUPlayerHostView()
        view.onLayout = { [weak coordinator] bounds, scale in
            coordinator?.updateInlineLayout(bounds: bounds, scale: scale)
        }
        context.coordinator.attach(to: view.metalLayer)
        return view
    }

    func updateUIView(_ view: TVGPUPlayerHostView, context: Context) {
        context.coordinator.updateInlineLayout(
            bounds: view.bounds,
            scale: view.window?.screen.nativeScale ?? view.traitCollection.displayScale
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
        @Published private(set) var status = "Starting tvOS shared-GPU renderer"
        @Published private(set) var backend = "PiP: automatic"

        var pendingURL: URL?
        var isPictureInPictureSupported: Bool {
            guard #available(tvOS 15.0, *) else { return false }
            return AVPictureInPictureController.isPictureInPictureSupported()
        }

        private var renderer: MPVGPUPlayerRenderer?
        private var pictureInPictureController: AVPictureInPictureController?
        private var pictureInPictureTask: Task<Void, Never>?
        private var pictureInPictureRequestGeneration: UInt64 = 0

        func attach(to layer: MPVGPUPlayerMetalLayer) {
            guard renderer == nil else { return }
            configureAudioSession()

            let options = MPVGPUPlayerRendererOptions(
                maximumPiPFrameSize: CGSize(width: 1920, height: 1080),
                pictureInPictureBackendPreference: .automatic,
                maximumInFlightPictureInPictureFrames: 3,
                pictureInPicturePreparationTimeout: 1
            )
            let renderer = MPVGPUPlayerRenderer(inlineLayer: layer, options: options)
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
            pictureInPictureController?.invalidatePlaybackState()
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
            guard #available(tvOS 15.0, *), let controller = pictureInPictureController else {
                status = "PiP requires tvOS 15 and supported hardware"
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
                // tvOS never auto-enters: only this host button initiates AVKit PiP.
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
                self?.pictureInPictureController?.invalidatePlaybackState()
                completion?()
            }
        }

        private func configureAudioSession() {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                status = "Audio session warning: \(error.localizedDescription)"
            }
        }

        private func configurePictureInPicture(for renderer: MPVGPUPlayerRenderer) {
            guard #available(tvOS 15.0, *), isPictureInPictureSupported else { return }
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
            pictureInPictureController?.invalidatePlaybackState()
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

@available(tvOS 15.0, *)
extension TVGPUPlayerView.Coordinator: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate, @preconcurrency AVPictureInPictureControllerDelegate {
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

private final class TVGPUPlayerHostView: UIView {
    override class var layerClass: AnyClass { MPVGPUPlayerMetalLayer.self }

    var metalLayer: MPVGPUPlayerMetalLayer { layer as! MPVGPUPlayerMetalLayer }
    var onLayout: ((CGRect, CGFloat) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds, window?.screen.nativeScale ?? traitCollection.displayScale)
    }
}
