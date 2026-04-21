import Foundation

enum TranscriptMerger {
    static func merge(
        whisper: Transcript,
        diarization: [RawSpeakerSegment]
    ) -> Transcript {
        let labeledSegments = labelSegments(whisper: whisper, diarization: diarization)

        var seen = Set<String>()
        var orderedRaw: [String] = []
        for seg in labeledSegments {
            if let sp = seg.speaker, !seen.contains(sp) {
                seen.insert(sp)
                orderedRaw.append(sp)
            }
        }

        return Transcript(
            audioFilename: whisper.audioFilename,
            modelId: whisper.modelId,
            language: whisper.language,
            createdAt: whisper.createdAt,
            fullText: whisper.fullText,
            segments: labeledSegments,
            words: whisper.words,
            rawSpeakers: orderedRaw,
            speakerNames: [:]
        )
    }

    private static func labelSegments(
        whisper: Transcript,
        diarization: [RawSpeakerSegment]
    ) -> [TranscriptSegment] {
        guard !diarization.isEmpty else {
            return whisper.segments
        }
        if let words = whisper.words, !words.isEmpty {
            return mergeFromWords(words: words, diarization: diarization)
        }
        return mergeFromSegments(segments: whisper.segments, diarization: diarization)
    }

    // Word-level merge: assign each word to the diarization turn covering its midpoint,
    // then collapse consecutive same-speaker words into one segment.
    private static func mergeFromWords(
        words: [TranscriptWord],
        diarization: [RawSpeakerSegment]
    ) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var currentSpeaker: String? = nil
        var currentWords: [TranscriptWord] = []

        for word in words {
            let midpoint = (word.start + word.end) / 2
            let speaker = speakerAt(time: midpoint, in: diarization)

            if speaker == currentSpeaker {
                currentWords.append(word)
            } else {
                if !currentWords.isEmpty {
                    result.append(makeSegment(words: currentWords, speaker: currentSpeaker))
                }
                currentSpeaker = speaker
                currentWords = [word]
            }
        }
        if !currentWords.isEmpty {
            result.append(makeSegment(words: currentWords, speaker: currentSpeaker))
        }
        return result
    }

    private static func mergeFromSegments(
        segments: [TranscriptSegment],
        diarization: [RawSpeakerSegment]
    ) -> [TranscriptSegment] {
        segments.map { seg in
            TranscriptSegment(
                start: seg.start,
                end: seg.end,
                text: seg.text,
                speaker: bestOverlap(for: seg, in: diarization)
            )
        }
    }

    private static func makeSegment(
        words: [TranscriptWord],
        speaker: String?
    ) -> TranscriptSegment {
        let joined = words
            .map { stripSpecialTokens($0.text) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return TranscriptSegment(
            start: words.first?.start ?? 0,
            end: words.last?.end ?? 0,
            text: joined,
            speaker: speaker
        )
    }

    private static func speakerAt(
        time: Double,
        in diarization: [RawSpeakerSegment]
    ) -> String? {
        for d in diarization where time >= d.start && time <= d.end {
            return d.speaker
        }
        // Gaps between pyannote turns (silence): pick the closest neighbor by time.
        var closest: String?
        var closestDistance: Double = .infinity
        for d in diarization {
            let distance = time < d.start ? (d.start - time) : (time - d.end)
            if distance < closestDistance {
                closestDistance = distance
                closest = d.speaker
            }
        }
        return closest
    }

    private static func bestOverlap(
        for segment: TranscriptSegment,
        in diarization: [RawSpeakerSegment]
    ) -> String? {
        var best: String?
        var bestOverlap: Double = 0
        for d in diarization {
            let overlap = max(0, min(segment.end, d.end) - max(segment.start, d.start))
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = d.speaker
            }
        }
        return best
    }

    private static func stripSpecialTokens(_ text: String) -> String {
        let pattern = #"<\|[^|]*\|>"#
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}
