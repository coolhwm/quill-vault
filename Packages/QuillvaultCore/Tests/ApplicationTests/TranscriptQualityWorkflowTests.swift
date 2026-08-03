import Application
import Domain
import Foundation
import Testing

@Suite("Transcript quality workflow")
struct TranscriptQualityWorkflowTests {
  @Test("Keeps original anchors when optimized line count mismatches")
  func keepsOriginalOnMismatch() async throws {
    let timeline = try TranscriptTimeline.normalizing(
      [
        TranscriptSegmentCandidate(startSeconds: 0, endSeconds: 1, text: "原始一句"),
        TranscriptSegmentCandidate(startSeconds: 1, endSeconds: 2, text: "原始二句"),
      ],
      audioDurationSeconds: 2
    )
    let provider = QualityProviderStub(output: "only one line")
    let workflow = TranscriptQualityWorkflow(
      profiles: QualityProfilesStub(),
      provider: provider
    )
    let result = try await workflow.optimize(
      timeline: timeline,
      localeIdentifier: "zh-CN"
    )
    #expect(result.timeline.segments.map(\.text) == ["原始一句", "原始二句"])
    #expect(result.metadata.strategyID == "offline-readability")
  }

  @Test("Applies line-aligned optimized text")
  func appliesAlignedOptimization() async throws {
    let timeline = try TranscriptTimeline.normalizing(
      [
        TranscriptSegmentCandidate(startSeconds: 0, endSeconds: 1, text: "因该开会"),
        TranscriptSegmentCandidate(startSeconds: 1, endSeconds: 2, text: "确认方案"),
      ],
      audioDurationSeconds: 2
    )
    let provider = QualityProviderStub(
      output: """
        - [000.0–001.0] 应该开会
        - [001.0–002.0] 确认方案
        """
    )
    let workflow = TranscriptQualityWorkflow(
      profiles: QualityProfilesStub(),
      provider: provider
    )
    let result = try await workflow.optimize(
      timeline: timeline,
      localeIdentifier: "zh-CN"
    )
    #expect(result.timeline.segments.map(\.text) == ["应该开会", "确认方案"])
  }

  @Test("Passthrough incremental port preserves segments")
  func passthroughIncremental() async throws {
    let port = PassthroughIncrementalTranscriptQuality()
    let segment = TranscriptSegmentCandidate(
      startSeconds: 0,
      endSeconds: 1,
      text: "hello"
    )
    let optimized = try await port.optimize(segment: segment, context: [])
    #expect(optimized == segment)
  }

  @Test("optimizeAndPublish leaves original fingerprint unchanged")
  func publishKeepsOriginalImmutable() async throws {
    let timeline = try TranscriptTimeline.normalizing(
      [
        TranscriptSegmentCandidate(startSeconds: 0, endSeconds: 1, text: "因该开会"),
        TranscriptSegmentCandidate(startSeconds: 1, endSeconds: 2, text: "确认方案"),
      ],
      audioDurationSeconds: 2
    )
    let meetingID = MeetingID(
      rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    )
    let original = TranscriptRevision(
      meetingID: meetingID,
      localeIdentifier: "zh-CN",
      timeline: timeline
    )
    let access = InMemoryTranscriptQualityAccess(original: original)
    let provider = QualityProviderStub(
      output: """
        - [000.0–001.0] 应该开会
        - [001.0–002.0] 确认方案
        """
    )
    let workflow = TranscriptQualityWorkflow(
      profiles: QualityProfilesStub(),
      provider: provider,
      access: access
    )
    let directory = AuthoritativeDirectory(
      id: AuthoritativeDirectoryID(rawValue: "dir"),
      displayName: "Vault",
      kind: .userSelected
    )
    let meeting = MeetingIndexEntry(
      id: meetingID,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      relativeDirectory: "meeting-20260101-000000",
      assets: [.transcript],
      durationSeconds: 2
    )
    let before = try await access.originalTranscriptFingerprint(
      in: directory,
      meeting: meeting
    )
    _ = try await workflow.optimizeAndPublish(in: directory, meeting: meeting)
    let after = try await access.originalTranscriptFingerprint(
      in: directory,
      meeting: meeting
    )
    #expect(before == after)
    #expect(before != nil)
    let optimized = try await access.loadOptimizedTranscript(
      in: directory,
      meeting: meeting
    )
    #expect(optimized?.timeline.segments.map(\.text) == ["应该开会", "确认方案"])
  }
}

private actor InMemoryTranscriptQualityAccess: TranscriptQualityAccess {
  private let original: TranscriptRevision
  private var originalBytes: String
  private var optimized: TranscriptRevision?

  init(original: TranscriptRevision) {
    self.original = original
    self.originalBytes = "original-\(original.contentFingerprint)"
  }

  func publishOptimized(
    _ revision: TranscriptRevision,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    metadata: TranscriptVersionMetadata
  ) async throws {
    optimized = revision
  }

  func loadOriginalTranscript(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> TranscriptRevision {
    original
  }

  func loadOptimizedTranscript(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> TranscriptRevision? {
    optimized
  }

  func originalTranscriptFingerprint(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> String? {
    originalBytes
  }
}

private struct QualityProfilesStub: ModelProfileExecutionAccess {
  func currentExecutionProfile() async throws -> ModelExecutionProfile {
    ModelExecutionProfile(
      snapshot: ModelProfileSnapshot(
        profileID: ModelProfileID(rawValue: UUID()),
        baseURL: URL(string: "https://api.example.com/v1")!,
        model: "test",
        parameters: ModelGenerationParameters(),
        credentialReference: ModelCredentialReference(rawValue: UUID())
      ),
      apiKey: "secret"
    )
  }

  func executionProfile(
    for snapshot: ModelProfileSnapshot
  ) async throws -> ModelExecutionProfile {
    try await currentExecutionProfile()
  }

  func registerUnfinishedTask(
    _ task: ModelProfileTaskReference,
    profileID: ModelProfileID
  ) async throws {}

  func finishTask(_ task: ModelProfileTaskReference) async throws {}

  func reconcileUnfinishedTasks(
    keeping taskReferences: Set<ModelProfileTaskReference>
  ) async throws {}
}

private struct QualityProviderStub: AIProvider {
  let output: String

  func test(
    profile: ModelProfileSnapshot,
    apiKey: String
  ) async throws -> ModelCapability {
    ModelCapability(providerDomain: "api.example.com", representativeContent: true)
  }

  func generate(
    _ request: AIRequest,
    profile: ModelProfileSnapshot,
    apiKey: String
  ) -> AsyncThrowingStream<AIEvent, Error> {
    let output = self.output
    return AsyncThrowingStream { continuation in
      continuation.yield(.textDelta(output))
      continuation.yield(.completed)
      continuation.finish()
    }
  }
}
