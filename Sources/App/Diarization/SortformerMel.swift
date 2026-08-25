// SortformerMel — NeMo 128-mel frontend for the Streaming Sortformer diarizer.
//
// Adapted from the Core AI model zoo's `SortformerDiarizer.swift` mel frontend
// (github.com/john-rocky/coreai-model-zoo, BSD-3-Clause), which is a faithful Swift port
// of NeMo's `AudioToMelSpectrogramPreprocessor` (inference path). The model weights it
// serves are NVIDIA Streaming Sortformer 4-spk v2 (CC-BY-4.0).
//
// Recipe (metadata.json): preemph 0.97 -> STFT n_fft=512 / win=400 Hann centered (reflect
// pad) / hop=160 -> librosa-slaney mel[128,257] -> log(mel + 2^-24), with `normalize=NA`
// (NO per-channel normalization — the Sortformer config) and a length padded to a multiple
// of 16 frames (NeMo pad_to). Output is mel-major `[128, frames]`.
//
// The STFT + linear-mel stage is bit-identical to NeMo (cos 1.000); the divergence only
// appears after the log, where it amplifies the near-silence floor — irrelevant to the 0.5
// activity decision. The mel gate therefore compares on the pre-log LINEAR stage
// (`linearMel`), never a whole-spectrogram log-mel cosine (see Documentation/VERIFICATION.md).

import Accelerate
import Foundation

/// Deterministic, stateless NeMo 128-mel frontend. Construct once with the shipped
/// librosa-slaney filterbank; reuse across chunks.
struct SortformerMel: Sendable {
    static let nFFT = 512
    static let winLength = 400
    static let hop = 160
    static let nMels = 128
    static let nFreq = nFFT / 2 + 1        // 257
    static let preemph: Float = 0.97
    static let logGuard = Float(pow(2.0, -24))   // 5.9604645e-08 (metadata.json log_guard)
    static let padTo = 16

    private let window: [Float]            // [nFFT] 400-pt Hann centered in 512
    private let cosMat: [Float]            // [nFreq, nFFT]
    private let sinMat: [Float]            // [nFreq, nFFT]
    private let melFilters: [Float]        // [nMels, nFreq] librosa-slaney, mel-major (row-major)

    /// - Parameter melFilters: the shipped `sortformer_mel_filters_128x257.f32`, row-major
    ///   `[128, 257]`.
    init(melFilters: [Float]) {
        precondition(melFilters.count == Self.nMels * Self.nFreq,
                     "mel_filters must be [128,257] = \(Self.nMels * Self.nFreq), got \(melFilters.count)")
        self.melFilters = melFilters

        var win = [Float](repeating: 0, count: Self.nFFT)
        let offset = (Self.nFFT - Self.winLength) / 2
        for n in 0..<Self.winLength {
            win[offset + n] = 0.5 - 0.5 * cos(2 * .pi * Float(n) / Float(Self.winLength - 1))
        }
        window = win

        var c = [Float](repeating: 0, count: Self.nFreq * Self.nFFT)
        var s = [Float](repeating: 0, count: Self.nFreq * Self.nFFT)
        for k in 0..<Self.nFreq {
            for n in 0..<Self.nFFT {
                let a = 2 * Float.pi * Float(k) * Float(n) / Float(Self.nFFT)
                c[k * Self.nFFT + n] = cos(a)
                s[k * Self.nFFT + n] = sin(a)
            }
        }
        cosMat = c
        sinMat = s
    }

    /// Pre-log LINEAR mel — mel-major `[128, frames]` plus the frame count. This is the stage
    /// the mel gate compares against the independent numpy golden (the log stage is skipped
    /// because it amplifies the silence floor and skews the cosine; see the file header).
    func linearMel(_ samples: [Float]) -> (mel: [Float], frames: Int) {
        let nFFT = Self.nFFT, hop = Self.hop, nFreq = Self.nFreq, nMels = Self.nMels
        let L = samples.count
        let rawFrames = L / hop + 1
        let frames = ((rawFrames + Self.padTo - 1) / Self.padTo) * Self.padTo
        let pad = nFFT / 2

        // preemphasis 0.97 (front-to-back so x[t-1] is the original sample).
        var y = [Float](repeating: 0, count: L)
        if L > 0 {
            y[0] = samples[0]
            for t in 1..<L { y[t] = samples[t] - Self.preemph * samples[t - 1] }
        }

        // center pad by n_fft/2 with REFLECT (reflect_101, edge not repeated) — matches
        // torch.stft(center=True, pad_mode='reflect'). Trailing pad_to frames stay zero.
        let needed = max(pad + L + pad, (frames - 1) * hop + nFFT)
        var padded = [Float](repeating: 0, count: needed)
        for t in 0..<L { padded[pad + t] = y[t] }
        if L > 1 {
            for k in 1...pad where pad - k >= 0 && k < L { padded[pad - k] = y[k] }          // left
            for k in 1...pad where pad + L - 1 + k < needed && L - 1 - k >= 0 {
                padded[pad + L - 1 + k] = y[L - 1 - k]                                        // right
            }
        }

        // window each hop into [nFFT, frames] (column = frame).
        var win = [Float](repeating: 0, count: nFFT * frames)
        for t in 0..<frames {
            let base = t * hop
            for n in 0..<nFFT { win[n * frames + t] = padded[base + n] * window[n] }
        }

        // re/im = cos/sin DFT basis @ windowed frames -> [nFreq, frames]; power = re^2 + im^2.
        var re = [Float](repeating: 0, count: nFreq * frames)
        var im = [Float](repeating: 0, count: nFreq * frames)
        vDSP_mmul(cosMat, 1, win, 1, &re, 1, vDSP_Length(nFreq), vDSP_Length(frames), vDSP_Length(nFFT))
        vDSP_mmul(sinMat, 1, win, 1, &im, 1, vDSP_Length(nFreq), vDSP_Length(frames), vDSP_Length(nFFT))
        let count = vDSP_Length(nFreq * frames)
        vDSP_vsq(re, 1, &re, 1, count)
        vDSP_vsq(im, 1, &im, 1, count)
        var power = [Float](repeating: 0, count: nFreq * frames)
        vDSP_vadd(re, 1, im, 1, &power, 1, count)

        // mel = mel_filters @ power -> [nMels, frames]. normalize=NA -> no per-channel norm.
        var mel = [Float](repeating: 0, count: nMels * frames)
        vDSP_mmul(melFilters, 1, power, 1, &mel, 1, vDSP_Length(nMels), vDSP_Length(frames), vDSP_Length(nFreq))
        return (mel, frames)
    }

    /// Log-mel exactly like NeMo (log of the linear mel + 2^-24 guard). Mel-major `[128, frames]`.
    func logMel(_ samples: [Float]) -> (mel: [Float], frames: Int) {
        var (mel, frames) = linearMel(samples)
        var guardV = Self.logGuard
        vDSP_vsadd(mel, 1, &guardV, &mel, 1, vDSP_Length(mel.count))
        var n32 = Int32(mel.count)
        vvlogf(&mel, mel, &n32)
        return (mel, frames)
    }
}
