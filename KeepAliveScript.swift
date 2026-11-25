import Foundation

/// 注入到网页里的“保活”脚本。
///
/// iOS 在 App 进入后台后会冻结 WKWebView 的 WebContent 进程，网页里的
/// WebSocket 和定时器都会停掉，悬浮窗就会定格。这里在页面里挂一个循环播放的
/// 静音 <audio>，让 WebKit 认为页面正在播放媒体，从而在后台继续运行。
enum KeepAliveScript {

    static let source = """
    (function () {
      if (window.__kfAudioReady) { return; }
      window.__kfAudioReady = true;

      var sampleRate = 8000;
      var seconds = 1;
      var samples = sampleRate * seconds;
      var buffer = new ArrayBuffer(44 + samples * 2);
      var view = new DataView(buffer);

      function writeString(offset, text) {
        for (var i = 0; i < text.length; i++) {
          view.setUint8(offset + i, text.charCodeAt(i));
        }
      }

      writeString(0, 'RIFF');
      view.setUint32(4, 36 + samples * 2, true);
      writeString(8, 'WAVE');
      writeString(12, 'fmt ');
      view.setUint32(16, 16, true);
      view.setUint16(20, 1, true);
      view.setUint16(22, 1, true);
      view.setUint32(24, sampleRate, true);
      view.setUint32(28, sampleRate * 2, true);
      view.setUint16(32, 2, true);
      view.setUint16(34, 16, true);
      writeString(36, 'data');
      view.setUint32(40, samples * 2, true);

      var url = URL.createObjectURL(new Blob([buffer], { type: 'audio/wav' }));
      var audio = document.createElement('audio');
      audio.src = url;
      audio.loop = true;
      audio.volume = 0.01;
      audio.setAttribute('playsinline', '');
      audio.style.display = 'none';

      function ensure() {
        try {
          if (!document.documentElement.contains(audio)) {
            (document.body || document.documentElement).appendChild(audio);
          }
          if (audio.paused) {
            var promise = audio.play();
            if (promise && promise.catch) { promise.catch(function () {}); }
          }
        } catch (error) {}
      }

      ensure();
      window.setInterval(ensure, 5000);
      document.addEventListener('visibilitychange', ensure);
      window.__kfAudio = audio;
    })();
    """
}
