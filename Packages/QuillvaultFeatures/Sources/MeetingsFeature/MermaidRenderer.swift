import Foundation
import SwiftUI

enum MermaidHTMLDocument {
  static let runtimeVersion = "11.16.0"
  static let runtimeSHA256 = "07fb9c98a9718885cb4b68c29bdfdbd1e96bc6e731f5387cdc70ce8aadd4b2a6"

  static func contentSecurityPolicy(nonce: String) -> String {
    "default-src 'none'; script-src 'self' 'nonce-\(nonce)'; style-src 'unsafe-inline'; img-src 'none'; font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
  }

  static func make(source: String) -> String {
    let encodedSource = jsonString(source)
    let nonce = UUID().uuidString
    return """
      <!doctype html>
      <html lang="en">
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(nonce: nonce))">
        <style>
          :root { color-scheme: light dark; }
          body { margin: 0; padding: 12px; background: transparent; color: CanvasText; font: -apple-system-body; }
          #diagram { width: 100%; overflow-x: auto; }
          #diagram svg { display: block; max-width: 100%; height: auto; margin: 0 auto; }
        </style>
      </head>
      <body>
        <div id="diagram" role="img" aria-label="Meeting relationship diagram"></div>
        <script src="mermaid.min.js"></script>
        <script nonce="\(nonce)">
          (async function () {
            try {
              mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: 'default' });
              const result = await mermaid.render('quillvault-diagram', \(encodedSource));
              document.getElementById('diagram').innerHTML = result.svg;
            } catch (error) {
              window.webkit.messageHandlers.mermaidFailure.postMessage('render-failed');
            }
          }());
        </script>
      </body>
      </html>
      """
  }

  private static func jsonString(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
      let encoded = String(data: data, encoding: .utf8)
    else {
      return "\"\""
    }
    return String(encoded.dropFirst().dropLast())
  }
}

#if canImport(WebKit)
  import WebKit

  struct MermaidDiagramView: View {
    let source: String
    @State private var renderFailed = false

    var body: some View {
      Group {
        if renderFailed {
          MermaidSourceFallback(source: source)
        } else {
          MermaidWebView(source: source) {
            renderFailed = true
          }
          .frame(minHeight: 140)
        }
      }
      .onAppear {
        renderFailed = false
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("minutes.detail.diagram.accessibility")
    }
  }

  private struct MermaidSourceFallback: View {
    let source: String

    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        Label("minutes.detail.diagram.unavailable", systemImage: "text.page.badge.magnifyingglass")
          .foregroundStyle(.secondary)
        Text(source)
          .font(.system(.footnote, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding()
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
  }

  private struct MermaidWebView: View {
    let source: String
    let onFailure: () -> Void

    var body: some View {
      MermaidWebViewRepresentable(source: source, onFailure: onFailure)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
  }

  private final class MermaidFailureHandler: NSObject, WKScriptMessageHandler {
    let onFailure: () -> Void

    init(onFailure: @escaping () -> Void) {
      self.onFailure = onFailure
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard message.name == "mermaidFailure" else { return }
      onFailure()
    }
  }

  #if os(iOS)
    private struct MermaidWebViewRepresentable: UIViewRepresentable {
      let source: String
      let onFailure: () -> Void

      func makeCoordinator() -> Coordinator {
        Coordinator(onFailure: onFailure)
      }

      func makeUIView(context: Context) -> WKWebView {
        let webView = context.coordinator.makeWebView()
        context.coordinator.load(source: source, in: webView)
        return webView
      }

      func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onFailure = onFailure
        if context.coordinator.loadedSource != source {
          context.coordinator.load(source: source, in: webView)
        }
      }

      static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.release(webView)
      }

      @MainActor
      final class Coordinator: NSObject, WKNavigationDelegate {
        var onFailure: () -> Void
        var loadedSource: String?
        private var failureHandler: MermaidFailureHandler?

        init(onFailure: @escaping () -> Void) {
          self.onFailure = onFailure
        }

        func makeWebView() -> WKWebView {
          let controller = WKUserContentController()
          let handler = MermaidFailureHandler { [weak self] in
            self?.onFailure()
          }
          controller.add(handler, name: "mermaidFailure")
          failureHandler = handler
          let configuration = WKWebViewConfiguration()
          configuration.userContentController = controller
          configuration.websiteDataStore = .nonPersistent()
          let webView = WKWebView(frame: .zero, configuration: configuration)
          webView.navigationDelegate = self
          webView.isOpaque = false
          webView.backgroundColor = .clear
          return webView
        }

        func load(source: String, in webView: WKWebView) {
          loadedSource = source
          webView.loadHTMLString(
            MermaidHTMLDocument.make(source: source),
            baseURL: Bundle.module.resourceURL
          )
        }

        func release(_ webView: WKWebView) {
          webView.stopLoading()
          webView.navigationDelegate = nil
          webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "mermaidFailure")
          failureHandler = nil
          loadedSource = nil
        }

        func webView(
          _ webView: WKWebView,
          decidePolicyFor navigationAction: WKNavigationAction,
          decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
          let url = navigationAction.request.url
          let isLocal = url == nil || url?.isFileURL == true || url?.scheme == "about"
          decisionHandler(isLocal ? .allow : .cancel)
        }

        func webView(
          _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) {
          onFailure()
        }

        func webView(
          _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
          withError error: Error
        ) {
          onFailure()
        }
      }
    }
  #elseif os(macOS)
    private struct MermaidWebViewRepresentable: NSViewRepresentable {
      let source: String
      let onFailure: () -> Void

      func makeCoordinator() -> Coordinator {
        Coordinator(onFailure: onFailure)
      }

      func makeNSView(context: Context) -> WKWebView {
        let webView = context.coordinator.makeWebView()
        context.coordinator.load(source: source, in: webView)
        return webView
      }

      func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onFailure = onFailure
        if context.coordinator.loadedSource != source {
          context.coordinator.load(source: source, in: webView)
        }
      }

      static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.release(webView)
      }

      @MainActor
      final class Coordinator: NSObject, WKNavigationDelegate {
        var onFailure: () -> Void
        var loadedSource: String?
        private var failureHandler: MermaidFailureHandler?

        init(onFailure: @escaping () -> Void) {
          self.onFailure = onFailure
        }

        func makeWebView() -> WKWebView {
          let controller = WKUserContentController()
          let handler = MermaidFailureHandler { [weak self] in
            self?.onFailure()
          }
          controller.add(handler, name: "mermaidFailure")
          failureHandler = handler
          let configuration = WKWebViewConfiguration()
          configuration.userContentController = controller
          configuration.websiteDataStore = .nonPersistent()
          let webView = WKWebView(frame: .zero, configuration: configuration)
          webView.navigationDelegate = self
          webView.setValue(false, forKey: "drawsBackground")
          return webView
        }

        func load(source: String, in webView: WKWebView) {
          loadedSource = source
          webView.loadHTMLString(
            MermaidHTMLDocument.make(source: source),
            baseURL: Bundle.module.resourceURL
          )
        }

        func release(_ webView: WKWebView) {
          webView.stopLoading()
          webView.navigationDelegate = nil
          webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "mermaidFailure")
          failureHandler = nil
          loadedSource = nil
        }

        func webView(
          _ webView: WKWebView,
          decidePolicyFor navigationAction: WKNavigationAction,
          decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
          let url = navigationAction.request.url
          let isLocal = url == nil || url?.isFileURL == true || url?.scheme == "about"
          decisionHandler(isLocal ? .allow : .cancel)
        }

        func webView(
          _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) {
          onFailure()
        }

        func webView(
          _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
          withError error: Error
        ) {
          onFailure()
        }
      }
    }
  #endif
#else
  struct MermaidDiagramView: View {
    let source: String

    var body: some View {
      Text(source)
        .font(.system(.footnote, design: .monospaced))
        .textSelection(.enabled)
    }
  }
#endif
