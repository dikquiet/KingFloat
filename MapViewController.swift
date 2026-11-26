import UIKit
import WebKit

final class MapViewController: UIViewController {

    private let siteURL = URL(string: "http://king.weilua.top/")!
    private let pip = PiPController()
    private let silentAudio = SilentAudioPlayer()

    private var webView: WKWebView!
    private var progressView: UIProgressView!
    private var spinner: UIActivityIndicatorView!
    private var statusLabel: UILabel!
    private var hintLabel: PaddedLabel!
    private var debugLabel: UILabel!
    private var pipButton: UIButton!

    private var progressObservation: NSKeyValueObservation?
    private var hintWorkItem: DispatchWorkItem?
    private var debugTimer: Timer?
    private var audioState = "?"
    private var pipStats = "idle"

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildWebView()
        buildStatusViews()
        buildControls()
        configurePiP()
        startDebugPolling()
        loadSite()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !pip.isRunning {
            silentAudio.stop()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        pip.updateLayerFrame(view.bounds)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: - Build

    private func buildWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: KeepAliveScript.earlySource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: KeepAliveScript.source,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false))

        let mapRectHandler = MapRectHandler()
        mapRectHandler.pip = pip
        configuration.userContentController.add(mapRectHandler, name: "mapRect")
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: MapRectScript.source,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true))

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            let progress = Float(webView.estimatedProgress)
            DispatchQueue.main.async {
                guard let self else { return }
                self.progressView.progress = progress
                self.progressView.isHidden = progress >= 1
            }
        }
    }

    private func buildStatusViews() {
        progressView = UIProgressView(progressViewStyle: .bar)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = UIColor(red: 0.16, green: 0.84, blue: 0.46, alpha: 1)
        progressView.trackTintColor = .clear
        progressView.isHidden = true
        view.addSubview(progressView)

        spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.startAnimating()

        statusLabel = UILabel()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = UIColor(white: 1, alpha: 0.78)
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "正在加载…"

        let centerStack = UIStackView(arrangedSubviews: [spinner, statusLabel])
        centerStack.translatesAutoresizingMaskIntoConstraints = false
        centerStack.axis = .vertical
        centerStack.alignment = .center
        centerStack.spacing = 10
        view.addSubview(centerStack)

        hintLabel = PaddedLabel()
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.textColor = .white
        hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintLabel.backgroundColor = UIColor(white: 0, alpha: 0.72)
        hintLabel.layer.cornerRadius = 14
        hintLabel.layer.cornerCurve = .continuous
        hintLabel.layer.masksToBounds = true
        hintLabel.alpha = 0
        view.addSubview(hintLabel)

        debugLabel = UILabel()
        debugLabel.translatesAutoresizingMaskIntoConstraints = false
        debugLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        debugLabel.textColor = UIColor(white: 1, alpha: 0.6)
        debugLabel.backgroundColor = UIColor(white: 0, alpha: 0.35)
        debugLabel.numberOfLines = 2
        debugLabel.text = "pip: idle"
        view.addSubview(debugLabel)

        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),

            centerStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300),

            hintLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 330),

            debugLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            debugLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 48),
            debugLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340)
        ])
    }

    private func buildControls() {
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 20
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        view.addSubview(blur)

        let reloadButton = makePillButton(title: "刷新", action: #selector(reloadSite))
        pipButton = makePillButton(title: "悬浮", action: #selector(togglePiP))

        let stack = UIStackView(arrangedSubviews: [reloadButton, pipButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.distribution = .fill
        blur.contentView.addSubview(stack)

        let helpButton = UIButton(type: .system)
        helpButton.translatesAutoresizingMaskIntoConstraints = false
        helpButton.setTitle("?", for: .normal)
        helpButton.setTitleColor(.white, for: .normal)
        helpButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        helpButton.backgroundColor = UIColor(white: 0, alpha: 0.5)
        helpButton.layer.cornerRadius = 16
        helpButton.addTarget(self, action: #selector(showHelp), for: .touchUpInside)
        view.addSubview(helpButton)

        NSLayoutConstraint.activate([
            blur.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            blur.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            blur.heightAnchor.constraint(equalToConstant: 56),

            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -8),

            reloadButton.widthAnchor.constraint(equalToConstant: 104),
            pipButton.widthAnchor.constraint(equalToConstant: 104),

            helpButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            helpButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            helpButton.widthAnchor.constraint(equalToConstant: 32),
            helpButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func makePillButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.backgroundColor = UIColor(white: 1, alpha: 0.12)
        button.layer.cornerRadius = 16
        button.layer.cornerCurve = .continuous
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func configurePiP() {
        pip.attach(webView: webView, hostView: view)
        pip.stateHandler = { [weak self] active in
            self?.updatePiPState(active)
        }
        pip.failureHandler = { [weak self] message in
            self?.showAlert(title: "悬浮窗没能打开", message: message)
        }
        pip.statsHandler = { [weak self] text in
            guard let self else { return }
            self.pipStats = text
            self.updateDebugLabel()
        }
    }

    // MARK: - Actions

    private func loadSite() {
        statusLabel.text = "正在加载…"
        statusLabel.isHidden = false
        spinner.startAnimating()

        var request = URLRequest(url: siteURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        webView.load(request)
    }

    @objc private func reloadSite() {
        webView.stopLoading()
        loadSite()
    }

    @objc private func togglePiP() {
        if pip.isRunning {
            pip.stop()
            return
        }
        silentAudio.start()
        pip.start()
    }

    private func updatePiPState(_ active: Bool) {
        pipButton.setTitle(active ? "关闭悬浮" : "悬浮", for: .normal)
        if active {
            showHint("已开启悬浮窗，切到其他 App 即可看到")
        } else {
            silentAudio.stop()
        }
    }

    // MARK: - Helpers

    private func startDebugPolling() {
        let timer = Timer(
            timeInterval: 2,
            target: self,
            selector: #selector(pollAudioState),
            userInfo: nil,
            repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        debugTimer = timer
        pollAudioState()
    }

    @objc private func pollAudioState() {
        guard let webView else { return }
        let script = "(function(){try{var a=window.__kfAudio;if(!a){return 'none';}return a.paused?'paused':'playing';}catch(e){return 'err';}})()"
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            self.audioState = (result as? String) ?? "?"
            self.updateDebugLabel()
        }
    }

    private func updateDebugLabel() {
        debugLabel.text = "pip: \(pipStats) audio=\(audioState)"
    }

    private func showHint(_ text: String) {
        hintWorkItem?.cancel()
        hintLabel.text = text
        UIView.animate(withDuration: 0.2) {
            self.hintLabel.alpha = 1
        }
        let item = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.4) {
                self?.hintLabel.alpha = 0
            }
        }
        hintWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    private func showAlert(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    private func showLoadError(_ error: Error) {
        spinner.stopAnimating()
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }
        statusLabel.text = "页面加载失败\n\(error.localizedDescription)\n点底部「刷新」重试"
        statusLabel.isHidden = false
    }

    @objc private func showHelp() {
        let message = """
        1. 在 App 里进入房间，等地图正常显示。
        2. 点底部「悬浮」，再切到其他 App，地图会以小窗浮在上面。
        3. 小窗可以拖动；点小窗上的返回按钮回到 App。
        4. 悬浮画面每 0.5 秒刷新一次，只用来查看，不能点击操作。
        5. 如果小窗没出现：设置 → 通用 → 画中画 → 打开「自动开启画中画」。
        """
        showAlert(title: "怎么用", message: message)
    }

    deinit {
        progressObservation?.invalidate()
        hintWorkItem?.cancel()
        debugTimer?.invalidate()
    }
}

// MARK: - WKNavigationDelegate

extension MapViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        statusLabel.text = "正在加载…"
        statusLabel.isHidden = false
        spinner.startAnimating()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        spinner.stopAnimating()
        statusLabel.isHidden = true
        progressView.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadSite()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }

        let allowedSchemes: Set<String> = [
            "http", "https", "about", "data", "blob", "file", "javascript", "ws", "wss"
        ]
        if !allowedSchemes.contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

// MARK: - WKUIDelegate

extension MapViewController: WKUIDelegate {

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }
}

// MARK: - PaddedLabel

final class PaddedLabel: UILabel {

    var textInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + textInsets.left + textInsets.right,
            height: size.height + textInsets.top + textInsets.bottom)
    }
}

// MARK: - 地图区域定位

enum MapRectScript {

    static let source = """
    (function () {
      function findMap() {
        var direct = document.querySelector('img[src*="map.txt.png"]');
        if (direct) { return direct; }
        var styled = document.querySelector('[style*="map.txt.png"]');
        if (styled) { return styled; }
        var canvases = document.querySelectorAll('canvas');
        var best = null;
        var bestArea = 0;
        for (var i = 0; i < canvases.length; i++) {
          var rect = canvases[i].getBoundingClientRect();
          var area = rect.width * rect.height;
          if (area > bestArea) { bestArea = area; best = canvases[i]; }
        }
        return best;
      }

      function send() {
        try {
          var element = findMap();
          if (!element) { return; }
          var rect = element.getBoundingClientRect();
          if (rect.width < 80 || rect.height < 80) { return; }
          window.webkit.messageHandlers.mapRect.postMessage({
            x: rect.left, y: rect.top, w: rect.width, h: rect.height
          });
        } catch (error) {}
      }

      window.__kfSendMapRect = send;
      window.addEventListener('resize', send);
      window.addEventListener('orientationchange', send);
      window.setInterval(send, 2000);
      send();
    })();
    """
}

final class MapRectHandler: NSObject, WKScriptMessageHandler {

    weak var pip: PiPController?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "mapRect",
              let body = message.body as? [String: Any],
              let x = (body["x"] as? NSNumber)?.doubleValue,
              let y = (body["y"] as? NSNumber)?.doubleValue,
              let width = (body["w"] as? NSNumber)?.doubleValue,
              let height = (body["h"] as? NSNumber)?.doubleValue else { return }

        pip?.updateMapRect(CGRect(x: x, y: y, width: width, height: height))
    }
}
