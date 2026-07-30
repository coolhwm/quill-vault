@preconcurrency import AVFoundation
import Domain
import Foundation

struct AVRecordedAudioMerger: RecordedAudioMerging {
  private final class ExportSessionBox: @unchecked Sendable {
    let value: AVAssetExportSession

    init(_ value: AVAssetExportSession) {
      self.value = value
    }
  }

  func merge(
    originalURL: URL,
    continuationURL: URL,
    candidateURL: URL
  ) async throws {
    guard
      FileManager.default.fileExists(atPath: originalURL.path),
      FileManager.default.fileExists(atPath: continuationURL.path),
      !FileManager.default.fileExists(atPath: candidateURL.path)
    else {
      throw RecordingError.recordingWriteFailed
    }

    let composition = AVMutableComposition()
    guard
      let destinationTrack = composition.addMutableTrack(
        withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    else {
      throw RecordingError.recordingWriteFailed
    }

    var insertionTime = CMTime.zero
    for url in [originalURL, continuationURL] {
      let asset = AVURLAsset(url: url)
      guard
        let sourceTrack = try await asset.loadTracks(
          withMediaType: .audio
        ).first
      else {
        throw RecordingError.invalidRecordedAudio
      }
      let duration = try await asset.load(.duration)
      guard duration.isNumeric, duration > .zero else {
        throw RecordingError.invalidRecordedAudio
      }
      try destinationTrack.insertTimeRange(
        CMTimeRange(start: .zero, duration: duration),
        of: sourceTrack,
        at: insertionTime
      )
      insertionTime = insertionTime + duration
    }

    guard
      let export = AVAssetExportSession(
        asset: composition,
        presetName: AVAssetExportPresetAppleM4A
      )
    else {
      throw RecordingError.recordingWriteFailed
    }

    do {
      if #available(iOS 18, macOS 15, *) {
        try await export.export(to: candidateURL, as: .m4a)
      } else {
        export.outputURL = candidateURL
        export.outputFileType = .m4a
        let exportBox = ExportSessionBox(export)
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          exportBox.value.exportAsynchronously {
            switch exportBox.value.status {
            case .completed:
              continuation.resume()
            case .cancelled:
              continuation.resume(throwing: CancellationError())
            default:
              continuation.resume(
                throwing: exportBox.value.error
                  ?? RecordingError.recordingWriteFailed
              )
            }
          }
        }
      }
    } catch is CancellationError {
      try? FileManager.default.removeItem(at: candidateURL)
      throw CancellationError()
    } catch {
      try? FileManager.default.removeItem(at: candidateURL)
      throw error as? RecordingError ?? .recordingWriteFailed
    }
  }
}
