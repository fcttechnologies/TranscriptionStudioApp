// Mel-frontend gate: the Swift SortformerMel linear-mel must match an INDEPENDENT NumPy golden
// (scripts/gen_mel_golden.py) on the pre-log LINEAR stage. Gating the log-mel on a whole-
// spectrogram cosine is the documented trap (log expands the silence floor and skews the metric
// even when the speech bins match exactly), so the comparison is on the linear stage.
//
// Uses the shipped mel filterbank from Application Support; enabled only when artifacts are present.

import Foundation
import Testing
@testable import TranscriptionKit

private struct MelGolden: Codable {
    let sampleRate: Int
    let nMels: Int
    let frames: Int
    let samples: [Float]
    let linearMel: [[Float]]   // mel-major [nMels][frames]
}

@Suite("Sortformer mel frontend")
struct SortformerMelTests {
    private static func loadGolden() throws -> MelGolden {
        let url = try #require(Bundle.module.url(forResource: "mel_golden", withExtension: "json"),
                               "mel_golden.json missing — run scripts/gen_mel_golden.py")
        return try JSONDecoder().decode(MelGolden.self, from: Data(contentsOf: url))
    }

    private static func cosine(_ a: ArraySlice<Float>, _ b: [Float]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for (x, y) in zip(a, b) { dot += Double(x) * Double(y); na += Double(x) * Double(x); nb += Double(y) * Double(y) }
        if na == 0 || nb == 0 { return 1.0 }   // both silent -> treat as match
        return dot / (sqrt(na) * sqrt(nb))
    }

    @Test("linear mel matches the NumPy golden on the linear stage",
          .enabled(if: SortformerModelStore().artifactsPresent))
    func linearMelMatchesGolden() throws {
        let golden = try Self.loadGolden()
        let filters = try SortformerModelStore().loadMelFilters()
        let mel = SortformerMel(melFilters: filters)

        let (linear, frames) = mel.linearMel(golden.samples)
        #expect(frames == golden.frames)
        #expect(linear.count == SortformerMel.nMels * frames)

        // Per-frame cosine over the 128 mel bins (mel-major [128, frames]).
        var minCos = 1.0
        var worstFrame = -1
        var checkedFrames = 0
        for f in 0..<frames {
            var swiftCol = [Float](repeating: 0, count: SortformerMel.nMels)
            var goldCol = [Float](repeating: 0, count: SortformerMel.nMels)
            for m in 0..<SortformerMel.nMels {
                swiftCol[m] = linear[m * frames + f]
                goldCol[m] = golden.linearMel[m][f]
            }
            let norm = goldCol.reduce(0) { $0 + $1 * $1 }
            guard norm > 1e-8 else { continue }   // skip silent frames (undefined direction)
            checkedFrames += 1
            let c = Self.cosine(swiftCol[...], goldCol)
            if c < minCos { minCos = c; worstFrame = f }
        }
        #expect(checkedFrames > 0)
        // Linear stage is bit-identical modulo fp32 order-of-operations — expect near 1.0.
        #expect(minCos >= 0.9999, "worst per-frame linear-mel cosine \(minCos) at frame \(worstFrame)")
    }
}
