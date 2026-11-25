import AVFoundation
import AVKit
import UIKit
import WebKit

/// 把 WKWebView 的截图以 2fps 送进画中画，实现“悬浮窗”。
final class PiPController: NSObject {

    var stateHandler: ((Bool) -> Void)?
    var failureHandler: ((String) -> Void)?

    var isRunning: Bool { isActive }

    private weak var webView: WKWebView?
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var pictureInPictureController: AVPictureInPictureController?
    private var possibilityObservation: NSKeyValueObservation?
    private var refreshTimer: Timer?
    private var frameIndex: Int64 = 0
    private var isActive = false
    private var isStarting = false
    private var isPlaying = true
    private var captureInFlight = false

    func attach(webView: WKWebView, hostView: UIView) {
        self.webView = webView

        displayLayer.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        hostView.layer.addSublayer(displayLayer)

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        pictureInPictureController = controller
    }

    func start() {
        guard !isActive, !isStarting else { return }
        guard let controller = pictureInPictureController else {
            failureHandler?("画中画初始化失败，请重启 App 再试")
            return
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            failureHandler?("这台设备不支持画中画")
            return
        }

        isStarting = true
        isPlaying = true
        captureFrame()
        startRefreshTimer()

        if controller.isPictureInPicturePossible {
            beginPictureInPicture()
            return
        }

        possibilityObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            guard let self, controller.isPictureInPicturePossible else { return }
            self.beginPictureInPicture()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.isStarting, !self.isActive else { return }
            self.reset()
            self.failureHandler?("画中画启动超时，请先确认页面已加载，再点一次『悬浮』")
        }
    }

    func stop() {
        possibilityObservation?.invalidate()
        possibilityObservation = nil

        guard let controller = pictureInPictureController else {
            reset()
            return
        }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            reset()
        }
    }

    // MARK: - Frames

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(handleTick),
            userInfo: nil,
            repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    @objc private func handleTick() {
        guard isActive else { return }
        captureFrame()
    }

    private func captureFrame() {
        guard let webView, !captureInFlight else { return }
        captureInFlight = true

        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: 360)
        configuration.afterScreenUpdates = false

        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self else { return }
            self.captureInFlight = false
            guard let image,
                  let sample = ImageFrame.makeSampleBuffer(
                    from: image,
                    maxDimension: 900,
                    frameIndex: self.frameIndex) else { return }

            self.frameIndex += 1
            if !self.displayLayer.isReadyForMoreMediaData {
                self.displayLayer.flush()
            }
            self.displayLayer.enqueue(sample)
        }
    }

    // MARK: - State

    private func beginPictureInPicture() {
        guard isStarting, !isActive, let controller = pictureInPictureController else { return }
        isStarting = false
        possibilityObservation?.invalidate()
        possibilityObservation = nil
        controller.startPictureInPicture()
    }

    private func reset() {
        isActive = false
        isStarting = false
        isPlaying = true
        captureInFlight = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        possibilityObservation?.invalidate()
        possibilityObservation = nil
        stateHandler?(false)
    }

    deinit {
        refreshTimer?.invalidate()
        possibilityObservation?.invalidate()
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPController: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isActive = true
        isStarting = false
        if refreshTimer == nil {
            startRefreshTimer()
        }
        stateHandler?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        reset()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        reset()
        failureHandler?("画中画启动失败：\(error.localizedDescription)")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        isPlaying = playing
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        !isPlaying
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // 系统按画面比例调整悬浮窗大小，这里不需要额外处理。
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
