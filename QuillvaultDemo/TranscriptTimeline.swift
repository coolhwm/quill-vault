import Foundation

/// Deterministic merge helpers for final transcript timelines after background catch-up.
enum TranscriptTimeline {
    /// Sorts by start, drops exact duplicate ranges/text, and prefers longer finals on overlap.
    static func mergeFinals(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let finals = segments.filter(\.isFinal).sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return lhs.endTime > rhs.endTime
            }
            return lhs.startTime < rhs.startTime
        }
        var merged: [TranscriptSegment] = []
        for segment in finals {
            guard let last = merged.last else {
                merged.append(segment)
                continue
            }
            if almostEqual(last.startTime, segment.startTime)
                && almostEqual(last.endTime, segment.endTime)
                && last.text == segment.text
            {
                continue // exact duplicate
            }
            if segment.startTime < last.endTime - 0.05 {
                // Overlap: keep the longer span, append remainder text only if non-overlapping tail.
                if segment.endTime <= last.endTime + 0.05 {
                    continue
                }
                let remainder = TranscriptSegment(
                    startTime: last.endTime,
                    endTime: segment.endTime,
                    text: segment.text,
                    isFinal: true
                )
                if remainder.endTime - remainder.startTime > 0.05 {
                    merged.append(remainder)
                }
                continue
            }
            merged.append(segment)
        }
        return merged
    }

    /// Returns true when finals cover `[0, duration]` without known interior gaps (>0.35s).
    static func coversRecordingDuration(
        _ segments: [TranscriptSegment],
        duration: TimeInterval,
        allowedGap: TimeInterval = 0.35,
        endTolerance: TimeInterval = 0.5
    ) -> Bool {
        let finals = mergeFinals(segments)
        guard duration >= 0 else { return false }
        guard !finals.isEmpty || duration < allowedGap else { return false }
        if finals.isEmpty { return true }

        var cursor = 0.0
        for segment in finals {
            if segment.startTime - cursor > allowedGap {
                return false
            }
            cursor = max(cursor, segment.endTime)
        }
        return cursor + endTolerance >= duration
    }

    static func lastCoveredEnd(in segments: [TranscriptSegment]) -> TimeInterval {
        mergeFinals(segments).map(\.endTime).max() ?? 0
    }

    private static func almostEqual(_ a: TimeInterval, _ b: TimeInterval) -> Bool {
        abs(a - b) < 0.05
    }
}
