import Domain
import Foundation
@preconcurrency import Speech
import Testing

@testable import SpeechTranscription

@Suite("SpeechAnalyzer transcription adapter")
struct SpeechAnalyzerTranscriptionEngineTests {
  @Test("The production adapter satisfies the domain port")
  func conformsToPort() {
    if #available(iOS 26.0, macOS 26.0, *) {
      let engine: any SpeechTranscriptionEngine =
        SpeechAnalyzerTranscriptionEngine()
      #expect(String(describing: type(of: engine)).contains("SpeechAnalyzer"))
    }
  }

  @Test("Unsupported dynamic locale maps to an actionable domain error")
  func unsupportedLocale() async {
    if #available(iOS 26.0, macOS 26.0, *) {
      let engine = SpeechAnalyzerTranscriptionEngine(
        dependencies: dependencies(supportedLocale: nil)
      )

      await #expect(throws: TranscriptError.unsupportedLocale("xx-Invalid")) {
        _ = try await engine.prepare(localeIdentifier: "xx-Invalid")
      }
    }
  }

  @Test("Asset installation failure is distinguished from recognition failure")
  func assetInstallationFailure() async {
    if #available(iOS 26.0, macOS 26.0, *) {
      let engine = SpeechAnalyzerTranscriptionEngine(
        dependencies: dependencies(
          supportedLocale: Locale(identifier: "zh-Hans"),
          status: .supported,
          installError: AssetFailure()
        )
      )

      await #expect(
        throws: TranscriptError.speechAssetsUnavailable("zh-Hans")
      ) {
        _ = try await engine.prepare(localeIdentifier: "zh-Hans")
      }
    }
  }

  @Test("An already-reserved locale remains available for transcription")
  func alreadyReservedLocaleIsAvailable() async throws {
    if #available(iOS 26.0, macOS 26.0, *) {
      let engine = SpeechAnalyzerTranscriptionEngine(
        dependencies: dependencies(
          supportedLocale: Locale(identifier: "en-US"),
          status: .installed,
          canReserve: false
        )
      )

      _ = try await engine.prepare(localeIdentifier: "en-US")
    }
  }

  @available(iOS 26.0, macOS 26.0, *)
  private func dependencies(
    supportedLocale: Locale?,
    status: AssetInventory.Status = .unsupported,
    installError: (any Error)? = nil,
    canReserve: Bool = true
  ) -> SpeechAnalyzerDependencies {
    SpeechAnalyzerDependencies(
      supportedLocale: { _ in supportedLocale },
      assetStatus: { _ in status },
      installAssets: { _ in
        if let installError {
          throw installError
        }
      },
      reserveLocale: { _ in canReserve },
      releaseLocale: { _ in true }
    )
  }
}

private struct AssetFailure: Error {}
