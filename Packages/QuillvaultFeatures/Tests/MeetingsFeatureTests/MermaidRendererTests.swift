import Foundation
import Testing

@testable import MeetingsFeature

@Suite("Offline Mermaid renderer")
struct MermaidRendererTests {
  @Test("Uses a pinned local runtime and a restrictive CSP")
  func htmlIsOfflineAndLockedDown() {
    let html = MermaidHTMLDocument.make(source: "flowchart TD\n  A[开始] --> B[完成]")

    #expect(html.contains("script src=\"mermaid.min.js\""))
    #expect(html.contains("script-src 'self'"))
    #expect(html.contains("nonce-"))
    #expect(html.contains("<script nonce=\""))
    #expect(html.contains("connect-src 'none'"))
    #expect(html.contains("img-src 'none'"))
    #expect(!html.contains("https://"))
    #expect(MermaidHTMLDocument.runtimeVersion == "11.16.0")
    #expect(MermaidHTMLDocument.runtimeSHA256.count == 64)
  }

  @Test("Escapes source before embedding it in JavaScript")
  func sourceIsJSONStringEncoded() {
    let html = MermaidHTMLDocument.make(source: "flowchart TD\n  A[\"quoted\"] --> B")

    #expect(html.contains("\\\"quoted\\\""))
    #expect(html.contains("mermaidFailure"))
  }
}
