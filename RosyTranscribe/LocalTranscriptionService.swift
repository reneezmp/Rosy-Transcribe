import Foundation
import AVFoundation
import CoreMedia
import Speech
import FluidAudio

/// Apple Speech supplies the words; FluidAudio supplies a speaker timeline.
/// The two systems never exchange audio or data with a server after their
/// models have been downloaded.
struct LocalTranscriptionService {

    func transcribe(fileURL: URL, language: TranscriptionLanguage,
                    expectedSpeakers: Int? = nil) async throws -> TranscriptionResponse {
        guard LocalTranscriptionAvailability.isAvailable else {
            throw TranscriptionError.localUnavailable
        }
        guard #available(macOS 26.0, *) else {
            throw TranscriptionError.localUnavailable
        }

        async let speech = transcribeWords(fileURL: fileURL, locale: language.appleLocale)
        async let speakers = diarize(fileURL: fileURL, expectedSpeakers: expectedSpeakers)
        let (recognizedWords, speakerSegments) = try await (speech, speakers)
        let words = Self.assignSpeakers(to: recognizedWords, from: speakerSegments)

        return TranscriptionResponse(
            text: words.map(\.text).joined(separator: " "),
            languageCode: language.appleLocale.language.languageCode?.identifier,
            languageProbability: nil,
            audioDurationSecs: try? Self.audioDuration(fileURL),
            words: words
        )
    }

    @available(macOS 26.0, *)
    private func transcribeWords(fileURL: URL, locale requestedLocale: Locale) async throws -> [TranscriptionWord] {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriptionError.localLanguageUnsupported(requestedLocale.localizedString(forIdentifier: requestedLocale.identifier) ?? requestedLocale.identifier)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }

        let resultTask = Task { () throws -> [TranscriptionWord] in
            var output: [TranscriptionWord] = []
            for try await result in transcriber.results {
                output.append(contentsOf: Self.words(from: result.text, fallbackRange: result.range))
            }
            return output
        }

        do {
            let file = try AVAudioFile(forReading: fileURL)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await resultTask.value
        } catch {
            resultTask.cancel()
            throw error
        }
    }

    private func diarize(fileURL: URL, expectedSpeakers: Int?) async throws -> [LocalSpeakerSegment] {
        try await Task.detached(priority: .userInitiated) {
            let models = try await DiarizerModels.downloadIfNeeded()
            let config = DiarizerConfig(
                // Stay close to FluidAudio's stable default. The previous
                // 0.62 experiment created a new identity for every acoustic
                // wobble and turned four people into fifteen.
                clusteringThreshold: 0.70,
                minSpeechDuration: 0.40,
                minEmbeddingUpdateDuration: 1.0,
                minSilenceGap: 0.2,
                numClusters: expectedSpeakers ?? -1,
                minActiveFramesCount: 5.0
            )
            let manager = DiarizerManager(config: config)
            manager.initialize(models: models)
            defer { manager.cleanup() }
            let samples = try AudioConverter().resampleAudioFile(fileURL)
            let result = try manager.performCompleteDiarization(samples)
            let segments = result.segments.map {
                LocalSpeakerSegment(id: $0.speakerId,
                                    start: Double($0.startTimeSeconds),
                                    end: Double($0.endTimeSeconds),
                                    embedding: $0.embedding)
            }
            guard let expectedSpeakers else { return segments }
            return Self.consolidate(segments, maximumSpeakers: expectedSpeakers)
        }.value
    }

    @available(macOS 26.0, *)
    private static func words(from text: AttributedString, fallbackRange: CMTimeRange) -> [TranscriptionWord] {
        var output: [TranscriptionWord] = []
        for run in text.runs {
            let content = String(text[run.range].characters)
            let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] ?? fallbackRange
            output.append(contentsOf: tokenize(content, in: range))
        }
        return output
    }

    private static func tokenize(_ text: String, in range: CMTimeRange) -> [TranscriptionWord] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let start = range.start.seconds
        let duration = max(0, range.duration.seconds)
        let totalCharacters = max(1, tokens.reduce(0) { $0 + $1.count })
        var consumed = 0
        return tokens.map { token in
            let tokenStart = start + duration * Double(consumed) / Double(totalCharacters)
            consumed += token.count
            let tokenEnd = start + duration * Double(consumed) / Double(totalCharacters)
            return TranscriptionWord(type: "word", text: token,
                                     start: tokenStart, end: tokenEnd, speakerId: nil)
        }
    }

    static func assignSpeakers(to words: [TranscriptionWord],
                               from segments: [LocalSpeakerSegment]) -> [TranscriptionWord] {
        let orderedIDs = segments.sorted { $0.start < $1.start }.reduce(into: [String]()) { ids, segment in
            if !ids.contains(segment.id) { ids.append(segment.id) }
        }
        let normalizedIDs = Dictionary(uniqueKeysWithValues:
            orderedIDs.enumerated().map { ($0.element, "speaker_\($0.offset)") })

        return words.map { word in
            guard let start = word.start, let end = word.end else { return word }
            let scored = segments.map { segment in
                (segment: segment, overlap: overlap(start, end, segment.start, segment.end))
            }
            let bestOverlap = scored.max { $0.overlap < $1.overlap }
            let chosen: LocalSpeakerSegment?
            if let bestOverlap, bestOverlap.overlap > 0 {
                chosen = bestOverlap.segment
            } else {
                // Diarizers deliberately leave uncertain regions blank. A
                // tiny boundary gap is safe to bridge; a larger one must stay
                // Unknown rather than being assigned to an arbitrary voice.
                let distances = segments.map { ($0, distance(start, end, $0.start, $0.end)) }
                    .sorted { $0.1 < $1.1 }
                if let nearest = distances.first, nearest.1 <= 0.45,
                   distances.count == 1 || distances[1].1 - nearest.1 > 0.05 {
                    chosen = nearest.0
                } else {
                    chosen = nil
                }
            }
            let speaker = chosen.flatMap { normalizedIDs[$0.id] }
            return TranscriptionWord(type: word.type, text: word.text,
                                     start: start, end: end, speakerId: speaker)
        }
    }

    /// FluidAudio 0.6 exposes `numClusters` but does not consume it. Enforce a
    /// requested upper bound ourselves by repeatedly joining the two closest
    /// duration-weighted voice embeddings. This cannot invent a missing
    /// speaker, but it reliably prevents the fifteen-alias disaster.
    static func consolidate(_ segments: [LocalSpeakerSegment],
                            maximumSpeakers: Int) -> [LocalSpeakerSegment] {
        guard maximumSpeakers > 0 else { return segments }
        var clusters = Dictionary(grouping: segments, by: \.id).map { id, members in
            SpeakerCluster(ids: [id], embedding: weightedEmbedding(members))
        }

        while clusters.count > maximumSpeakers {
            var bestPair: (Int, Int)?
            var bestDistance = Double.infinity
            for left in clusters.indices {
                for right in clusters.indices where right > left {
                    let distance = cosineDistance(clusters[left].embedding, clusters[right].embedding)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestPair = (left, right)
                    }
                }
            }
            guard let (left, right) = bestPair else { break }
            let joinedIDs = clusters[left].ids.union(clusters[right].ids)
            let joinedSegments = segments.filter { joinedIDs.contains($0.id) }
            clusters[left] = SpeakerCluster(ids: joinedIDs, embedding: weightedEmbedding(joinedSegments))
            clusters.remove(at: right)
        }

        let canonical = clusters.reduce(into: [String: String]()) { map, cluster in
            let id = cluster.ids.sorted().first ?? "unknown"
            for member in cluster.ids { map[member] = id }
        }
        return segments.map {
            LocalSpeakerSegment(id: canonical[$0.id] ?? $0.id,
                                start: $0.start, end: $0.end, embedding: $0.embedding)
        }
    }

    private static func weightedEmbedding(_ segments: [LocalSpeakerSegment]) -> [Float] {
        guard let size = segments.first(where: { !$0.embedding.isEmpty })?.embedding.count else { return [] }
        var sum = Array(repeating: 0.0, count: size)
        var totalWeight = 0.0
        for segment in segments where segment.embedding.count == size {
            let weight = max(0.01, segment.end - segment.start)
            totalWeight += weight
            for index in 0..<size { sum[index] += Double(segment.embedding[index]) * weight }
        }
        guard totalWeight > 0 else { return [] }
        return sum.map { Float($0 / totalWeight) }
    }

    private static func cosineDistance(_ left: [Float], _ right: [Float]) -> Double {
        guard !left.isEmpty, left.count == right.count else { return .infinity }
        var dot = 0.0
        var leftMagnitude = 0.0
        var rightMagnitude = 0.0
        for index in left.indices {
            let a = Double(left[index])
            let b = Double(right[index])
            dot += a * b
            leftMagnitude += a * a
            rightMagnitude += b * b
        }
        guard leftMagnitude > 0, rightMagnitude > 0 else { return .infinity }
        return 1 - dot / (sqrt(leftMagnitude) * sqrt(rightMagnitude))
    }

    private static func overlap(_ aStart: Double, _ aEnd: Double,
                                _ bStart: Double, _ bEnd: Double) -> Double {
        max(0, min(aEnd, bEnd) - max(aStart, bStart))
    }

    private static func distance(_ aStart: Double, _ aEnd: Double,
                                 _ bStart: Double, _ bEnd: Double) -> Double {
        if overlap(aStart, aEnd, bStart, bEnd) > 0 { return 0 }
        if aEnd <= bStart { return bStart - aEnd }
        return aStart - bEnd
    }

    private static func audioDuration(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

struct LocalSpeakerSegment: Equatable {
    let id: String
    let start: Double
    let end: Double
    let embedding: [Float]

    init(id: String, start: Double, end: Double, embedding: [Float] = []) {
        self.id = id
        self.start = start
        self.end = end
        self.embedding = embedding
    }
}

private struct SpeakerCluster {
    var ids: Set<String>
    var embedding: [Float]
}
