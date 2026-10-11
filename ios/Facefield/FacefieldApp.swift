import SwiftUI
import WebKit

@main
struct FacefieldApp: App {
    var body: some Scene {
        WindowGroup {
            FacefieldView()
                .ignoresSafeArea()
                .background(Color.black)
                .statusBarHidden()
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}

/// Hosts the Facefield web renderer and feeds it ARKit frames.
struct FacefieldView: UIViewRepresentable {
    func makeCoordinator() -> FaceStreamer { FaceStreamer() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "facefield")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.isInspectable = true
        context.coordinator.webView = web

        guard let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") else {
            web.loadHTMLString("<body style='background:#000;color:#fff;font:16px -apple-system'>web/index.html is missing from the app bundle.</body>", baseURL: nil)
            return web
        }
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// WKUserContentController retains its handlers; this breaks the cycle with the coordinator.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}
