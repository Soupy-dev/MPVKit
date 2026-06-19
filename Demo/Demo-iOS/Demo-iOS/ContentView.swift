import AVFoundation
import AVKit
import MPVKitSampleBufferGPL
import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var coordinator = MPVMetalPlayerView.Coordinator()
    @ObservedObject fileprivate var sampleBufferCoordinator = MetalSampleBufferPlayerView.Coordinator()
    @State var loading = false
    @State private var mode: DemoMode = .metalLayer

    private enum DemoMode: String, CaseIterable, Identifiable {
        case metalLayer = "Metal Layer"
        case sampleBuffer = "Metal Sample Buffer"

        var id: String { rawValue }
    }

    private let defaultURL = URL(string: "https://github.com/mpvkit/video-test/raw/master/resources/HDR10_ToneMapping_Test_240_1000_nits.mp4")!

    var body: some View {
        VStack {
            Picker("Renderer", selection: $mode) {
                ForEach(DemoMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            switch mode {
            case .metalLayer:
                MPVMetalPlayerView(coordinator: coordinator)
                    .play(defaultURL)
                    .onPropertyChange { _, propertyName, propertyData in
                        switch propertyName {
                        case MPVProperty.pausedForCache:
                            loading = propertyData as? Bool ?? false
                        default:
                            break
                        }
                    }
            case .sampleBuffer:
                MetalSampleBufferPlayerView(coordinator: sampleBufferCoordinator)
                    .play(defaultURL)
                    .onLoadingChange { isLoading in
                        loading = isLoading
                    }
            }
        }
        .overlay {
            VStack {
                Spacer()
                if mode == .sampleBuffer {
                    HStack {
                        Button(sampleBufferCoordinator.isPaused ? "Play" : "Pause") {
                            sampleBufferCoordinator.togglePause()
                        }
                        Button("-10") {
                            sampleBufferCoordinator.seek(by: -10)
                        }
                        Button("+10") {
                            sampleBufferCoordinator.seek(by: 10)
                        }
                        Button("Sub") {
                            sampleBufferCoordinator.selectNextSubtitleTrack()
                        }
                        Button("PiP") {
                            sampleBufferCoordinator.togglePictureInPicture()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                }
                ScrollView(.horizontal) {
                    HStack {
                        Button {
                            play(URL(string: "https://vjs.zencdn.net/v/oceans.mp4")!)
                        } label: {
                            Text("h264").frame(width: 130, height: 100)
                        }
                        Button {
                            play(URL(string: "https://github.com/mpvkit/video-test/raw/master/resources/h265.mp4")!)
                        } label: {
                            Text("h265").frame(width: 130, height: 100)
                        }
                        Button {
                            play(URL(string: "https://github.com/mpvkit/video-test/raw/master/resources/pgs_subtitle.mkv")!)
                        } label: {
                            Text("subtitle").frame(width: 130, height: 100)
                        }
                        Button {
                            play(URL(string: "https://github.com/mpvkit/video-test/raw/master/resources/hdr.mkv")!)
                        } label: {
                            Text("HDR").frame(width: 130, height: 100)
                        }
                        Button {
                            play(URL(string: "https://github.com/mpvkit/video-test/raw/master/resources/DolbyVision_P5.mp4")!)
                        } label: {
                            Text("DV_P5").frame(width: 130, height: 100)
                        }
                        Button {
                            play(URL(string: "https://github.com/mpvkit/video-test/raw/master/resources/DolbyVision_P8.mp4")!)
                        } label: {
                            Text("DV_P8").frame(width: 130, height: 100)
                        }
                    }
                }
            }
        }
        .overlay(overlayView)
        .preferredColorScheme(.dark)
    }

    private func play(_ url: URL) {
        switch mode {
        case .metalLayer:
            coordinator.play(url)
        case .sampleBuffer:
            sampleBufferCoordinator.play(url)
        }
    }

    @ViewBuilder
    private var overlayView: some View {
        if loading {
            ProgressView()
        } else {
            EmptyView()
        }
    }
}

private struct MetalSampleBufferPlayerView: UIViewRepresentable {
    @ObservedObject var coordinator: Coordinator

    func makeCoordinator() -> Coordinator {
        coordinator
    }

    func makeUIView(context: Context) -> SampleBufferHostView {
        let view = SampleBufferHostView()
        context.coordinator.attach(to: view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: SampleBufferHostView, context: Context) {}

    func play(_ url: URL) -> Self {
        coordinator.playUrl = url
        return self
    }

    func onLoadingChange(_ handler: @escaping (Bool) -> Void) -> Self {
        coordinator.onLoadingChange = handler
        return self
    }

    final class Coordinator: NSObject, ObservableObject {
        @Published var isPaused = true

        var playUrl: URL?
        var onLoadingChange: ((Bool) -> Void)?
        private var renderer: MPVMetalSampleBufferRenderer?
        private var pipController: AVPictureInPictureController?

        func attach(to displayLayer: AVSampleBufferDisplayLayer) {
            let renderer = MPVMetalSampleBufferRenderer(displayLayer: displayLayer)
            renderer.onStateChange = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .loading, .starting:
                        self?.onLoadingChange?(true)
                    case .playing:
                        self?.isPaused = false
                        self?.pipController?.invalidatePlaybackState()
                    case .paused:
                        self?.isPaused = true
                        self?.pipController?.invalidatePlaybackState()
                    default:
                        self?.onLoadingChange?(false)
                    }
                }
            }
            renderer.onError = { error in
                print("[MetalSampleBufferDemo] \(error)")
            }
            do {
                try renderer.start()
                if let playUrl {
                    renderer.load(playUrl)
                    renderer.play()
                    isPaused = false
                }
            } catch {
                print("[MetalSampleBufferDemo] start failed: \(error)")
            }
            self.renderer = renderer
            configurePictureInPicture(displayLayer: displayLayer)
        }

        func play(_ url: URL) {
            playUrl = url
            renderer?.load(url)
            renderer?.play()
            isPaused = false
            pipController?.invalidatePlaybackState()
        }

        func togglePause() {
            guard let renderer else { return }
            if isPaused {
                renderer.play()
                isPaused = false
            } else {
                renderer.pause()
                isPaused = true
            }
            pipController?.invalidatePlaybackState()
        }

        func seek(by seconds: Double) {
            renderer?.seek(by: seconds)
            renderer?.primeFrames(reason: "demo-seek", count: 4)
            pipController?.invalidatePlaybackState()
        }

        func selectNextSubtitleTrack() {
            guard let renderer else { return }
            let tracks = renderer.subtitleTracks()
            let current = renderer.currentSubtitleTrackID()
            if let index = tracks.firstIndex(where: { $0.id == current }),
               tracks.indices.contains(index + 1) {
                renderer.setSubtitleTrack(id: tracks[index + 1].id)
            } else if let first = tracks.first {
                renderer.setSubtitleTrack(id: first.id)
            } else {
                renderer.disableSubtitles()
            }
            renderer.primeFrames(reason: "demo-subtitle-switch", count: 4)
        }

        func togglePictureInPicture() {
            guard let pipController else {
                print("[MetalSampleBufferDemo] PiP unavailable")
                return
            }
            renderer?.primeFrames(reason: "demo-pip", count: 8)
            if pipController.isPictureInPictureActive {
                pipController.stopPictureInPicture()
            } else if pipController.isPictureInPicturePossible {
                pipController.startPictureInPicture()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, self.pipController?.isPictureInPictureActive == false else { return }
                    self.pipController?.startPictureInPicture()
                }
            }
        }

        private func configurePictureInPicture(displayLayer: AVSampleBufferDisplayLayer) {
            guard #available(iOS 15.0, *),
                  AVPictureInPictureController.isPictureInPictureSupported() else {
                return
            }
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.requiresLinearPlayback = false
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            pipController = controller
        }
    }
}

@available(iOS 15.0, *)
extension MetalSampleBufferPlayerView.Coordinator: AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        if playing {
            renderer?.play()
            isPaused = false
        } else {
            renderer?.pause()
            isPaused = true
        }
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let duration = max(renderer?.duration ?? 0, 1)
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        isPaused
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        renderer?.primeFrames(reason: "demo-pip-render-size", count: 3)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        renderer?.seek(by: skipInterval.seconds)
        renderer?.primeFrames(reason: "demo-pip-skip", count: 4)
        pictureInPictureController.invalidatePlaybackState()
        completionHandler()
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }
}

private final class SampleBufferHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }
}
