import AVFoundation
import AVKit
import UIKit
import WebKit

/// 把 WKWebView 的截图以 2fps 送进画中画，实现“悬浮窗”。
final class PiPController: NSObject {

    var stateHandler: ((Bool) -> Void)?
    var failureHandler: ((String) -> Void)?
    var statsHandler: ((String) -> Void)?

    var isRunning: Bool { isActive }

    private weak var webView: WKWebView?
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var pictureInPictureController: AVPictureInPictureController?
    private var possibilityObservation: NSKeyValueObservation?
    private var refreshTimer: Timer?
    private var timebase: CMTimebase?
    private var frameIndex: Int64 = 0
    private var isActive = false
    private var isStarting = false
    private var isPlaying = true
    private var captureInFlight = false
    private var enqueuedCount = 0
    private var snapshotFailures = 0
    private var lastError = "none"
    private var mapRect: CGRect?

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

    func updateLayerFrame(_ bounds: CGRect) {
        // 画中画内容由 sample buffer 决定，layer 只作为挂载点，保持很小的尺寸即可。
        displayLayer.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
    }

    func updateMapRect(_ rect: CGRect) {
        mapRect = rect
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
        frameIndex = 0
        enqueuedCount = 0
        snapshotFailures = 0
        lastError = "none"
        prepareTimebase()
        enqueueTestPattern()
        captureFrame()
        startRefreshTimer()
        reportStats()

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

    // MARK: - Timebase

    private func prepareTimebase() {
        var tb: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb)
        guard status == noErr, let tb else {
            timebase = nil
            return
        }
        CMTimebaseSetTime(tb, time: .zero)
        CMTimebaseSetRate(tb, rate: 1)
        displayLayer.controlTimebase = tb
        timebase = tb
    }

    private func nextPresentationIndex() -> Int64 {
        if let timebase {
            let seconds = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
            if seconds.isFinite, seconds >= 0 {
                return Int64((seconds * 2).rounded(.down))
            }
        }
        frameIndex += 1
        return frameIndex
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
        configuration.afterScreenUpdates = true
        configuration.rect = captureRect(for: webView)

        webView.takeSnapshot(with: configuration) { [weak self] image, error in
            guard let self else { return }
            self.captureInFlight = false
            guard let image else {
                self.snapshotFailures += 1
                self.lastError = error?.localizedDescription ?? "snapshot nil"
                self.reportStats()
                return
            }
            self.enqueue(image: image)
        }
    }

    /// 只截地图区域；拿不到地图位置时退回“页面中上部方形”的默认区域。
    private func captureRect(for webView: WKWebView) -> CGRect {
        let bounds = CGRect(origin: .zero, size: webView.bounds.size)
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        if let mapRect, mapRect.width > 80, mapRect.height > 80 {
            let clipped = mapRect.intersection(bounds)
            if clipped.width > 80, clipped.height > 80 {
                return clipped
            }
        }

        let side = min(bounds.width, bounds.height)
        let y = min(max(0, bounds.height * 0.16), max(0, bounds.height - side))
        return CGRect(x: 0, y: y, width: bounds.width, height: side)
    }

    private func enqueueTestPattern() {
        guard let image = PiPController.makeTestImage() else { return }
        enqueue(image: image)
    }

    private func enqueue(image: UIImage) {
        let presentationIndex = nextPresentationIndex()
        guard let sample = ImageFrame.makeSampleBuffer(
            from: image,
            maxDimension: 900,
            frameIndex: presentationIndex) else {
            lastError = "buffer create failed"
            reportStats()
            return
        }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sample)
        enqueuedCount += 1
        reportStats()
    }

    private func reportStats() {
        let layerStatus: String
        switch displayLayer.status {
        case .rendering: layerStatus = "rendering"
        case .failed: layerStatus = "failed"
        default: layerStatus = "unknown"
        }
        let text = "f=\(enqueuedCount) fail=\(snapshotFailures) layer=\(layerStatus) ready=\(displayLayer.isReadyForMoreMediaData ? 1 : 0) err=\(lastError)"
        statsHandler?(text)
    }

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
        timebase = nil
        displayLayer.controlTimebase = nil
        displayLayer.flush()
        stateHandler?(false)
    }

    private static func makeTestImage() -> UIImage? {
        let size = CGSize(width: 720, height: 1280)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let colors: [CGColor] = [
                UIColor(red: 0.03, green: 0.09, blue: 0.13, alpha: 1).cgColor,
                UIColor(red: 0.05, green: 0.35, blue: 0.22, alpha: 1).cgColor
            ]
            let locations: [CGFloat] = [0, 1]
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: locations) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: 0, y: size.height),
                    options: [])
            }

            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 86, weight: .heavy),
                .foregroundColor: UIColor.white
            ]
            let subtitleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 44, weight: .medium),
                .foregroundColor: UIColor(white: 1, alpha: 0.7)
            ]

            let title = "KINGFLOAT" as NSString
            let subtitle = "TEST FRAME" as NSString
            let titleSize = title.size(withAttributes: titleAttributes)
            let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)
            title.draw(
                at: CGPoint(x: (size.width - titleSize.width) / 2, y: size.height / 2 - 120),
                withAttributes: titleAttributes)
            subtitle.draw(
                at: CGPoint(x: (size.width - subtitleSize.width) / 2, y: size.height / 2 + 20),
                withAttributes: subtitleAttributes)
        }
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
        // 实时内容，固定返回“无限长”的直播时间范围。
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
