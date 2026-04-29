import Foundation
import UIKit
import WebKit

/// Загружает `GET /auth/recaptcha-embed` (см. [reCAPTCHA v3](https://developers.google.com/recaptcha/docs/v3)) и забирает токен через `WKScriptMessageHandler`.
@MainActor
final class RecaptchaTokenLoader: NSObject, WKScriptMessageHandler {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let lock = NSLock()
    private var didFinish = false
    private let embedURL: URL

    init(baseURL: String) {
        var u = baseURL
        if u.hasSuffix("/") { u.removeLast() }
        self.embedURL = URL(string: u + "/auth/recaptcha-embed")!
        super.init()
    }

    func loadToken() async -> String? {
        // Try google endpoint first, then recaptcha.net as fallback.
        if let t = await loadTokenOnce(url: embedURL) { return t }
        guard var alt = URLComponents(url: embedURL, resolvingAgainstBaseURL: false) else { return nil }
        alt.queryItems = (alt.queryItems ?? []) + [URLQueryItem(name: "alt", value: "1")]
        return await loadTokenOnce(url: alt.url!)
    }

    private func loadTokenOnce(url: URL) async -> String? {
        didFinish = false
        return await withCheckedContinuation { cont in
            self.continuation = cont
            let config = WKWebViewConfiguration()
            config.userContentController.add(self, name: "recaptcha")
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
            wv.isOpaque = false
            wv.alpha = 0.01
            self.webView = wv
            if let w = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) {
                w.addSubview(wv)
            }
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            wv.load(req)
            self.timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                self.finishWith(nil)
            }
        }
    }

    private func finishWith(_ token: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return }
        didFinish = true
        timeoutTask?.cancel()
        timeoutTask = nil
        if let wv = webView {
            wv.stopLoading()
            wv.removeFromSuperview()
        }
        webView = nil
        continuation?.resume(returning: token)
        continuation = nil
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            let body = message.body
            let token = body as? String
            if let t = token, !t.isEmpty { self.finishWith(t) } else { self.finishWith(nil) }
        }
    }
}
