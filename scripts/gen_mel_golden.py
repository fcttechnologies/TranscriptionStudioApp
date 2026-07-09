#!/usr/bin/env python3
"""Independent NumPy reference for the Sortformer NeMo 128-mel frontend — generates the
golden LINEAR mel that Tests/TranscriptionKitTests gates SortformerMel against.

Independent by construction: the STFT / framing / windowing / mel-matmul are implemented
here in plain NumPy (no NeMo, no librosa, not the zoo's Swift/Python code). It reuses only
the shipped librosa-slaney filterbank as data (the model's own filterbank), so the gate
isolates the DSP path. It compares on the pre-LOG linear stage — the log amplifies the
near-silence floor and skews a whole-spectrogram cosine even when the speech bins match
exactly (the documented cosine trap; see Documentation/VERIFICATION.md).

Recipe (metadata.json): preemph 0.97 -> STFT n_fft=512 / win=400 Hann centered (reflect
pad) / hop=160 -> slaney mel[128,257] -> (log skipped for the gate), normalize=NA,
frames padded up to a multiple of 16.

Run:  .venv-verify/bin/python scripts/gen_mel_golden.py
Out:  Tests/TranscriptionKitTests/Resources/mel_golden.json  (committed; self-contained)
"""
import json
import os
import struct
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
FILTERBANK = os.path.join(
    os.path.expanduser("~"),
    "Library/Application Support/TranscriptionStudio/Models/sortformer_mel_filters_128x257.f32",
)
OUT = os.path.join(REPO, "Tests/TranscriptionKitTests/Resources/mel_golden.json")

N_FFT = 512
WIN = 400
HOP = 160
N_MELS = 128
N_FREQ = N_FFT // 2 + 1  # 257
PREEMPH = 0.97
PAD_TO = 16
SAMPLE_RATE = 16000


def load_filterbank(path):
    with open(path, "rb") as f:
        data = f.read()
    vals = struct.unpack(f"<{len(data)//4}f", data)
    arr = np.array(vals, dtype=np.float64).reshape(N_MELS, N_FREQ)
    return arr


def synth_waveform(seconds=2.0):
    """Deterministic voiced-ish test signal: two formant-like tones with vibrato plus a
    touch of noise, bracketed by silence so the frontend sees a real dynamic range."""
    rng = np.random.default_rng(20260709)
    n = int(seconds * SAMPLE_RATE)
    t = np.arange(n) / SAMPLE_RATE
    sig = (
        0.6 * np.sin(2 * np.pi * (180 + 6 * np.sin(2 * np.pi * 4 * t)) * t)
        + 0.3 * np.sin(2 * np.pi * 720 * t)
        + 0.15 * np.sin(2 * np.pi * 1440 * t)
    )
    sig += 0.01 * rng.standard_normal(n)
    # 100 ms of silence at each end.
    edge = int(0.1 * SAMPLE_RATE)
    sig[:edge] = 0.0
    sig[-edge:] = 0.0
    return sig.astype(np.float64)


def hann_centered():
    w = np.zeros(N_FFT, dtype=np.float64)
    offset = (N_FFT - WIN) // 2
    for nn in range(WIN):
        w[offset + nn] = 0.5 - 0.5 * np.cos(2 * np.pi * nn / (WIN - 1))
    return w


def linear_mel(samples, mel_fb):
    L = len(samples)
    raw_frames = L // HOP + 1
    frames = ((raw_frames + PAD_TO - 1) // PAD_TO) * PAD_TO
    pad = N_FFT // 2

    # preemphasis (front-to-back).
    y = samples.copy()
    if L > 1:
        y[1:] = samples[1:] - PREEMPH * samples[:-1]

    # reflect center-pad by n_fft/2 (reflect_101: edge not repeated), then trailing zeros so
    # every one of `frames` windows fits.
    needed = max(pad + L + pad, (frames - 1) * HOP + N_FFT)
    padded = np.zeros(needed, dtype=np.float64)
    padded[pad:pad + L] = y
    if L > 1:
        for k in range(1, pad + 1):
            if pad - k >= 0 and k < L:
                padded[pad - k] = y[k]
            if pad + L - 1 + k < needed and L - 1 - k >= 0:
                padded[pad + L - 1 + k] = y[L - 1 - k]

    window = hann_centered()
    # DFT basis.
    kk = np.arange(N_FREQ).reshape(N_FREQ, 1)
    nn = np.arange(N_FFT).reshape(1, N_FFT)
    ang = 2 * np.pi * kk * nn / N_FFT
    cos_mat = np.cos(ang)
    sin_mat = np.sin(ang)

    power = np.zeros((N_FREQ, frames), dtype=np.float64)
    for t in range(frames):
        base = t * HOP
        frame = padded[base:base + N_FFT] * window
        re = cos_mat @ frame
        im = sin_mat @ frame
        power[:, t] = re * re + im * im

    mel = mel_fb @ power  # [n_mels, frames]
    return mel, frames


def main():
    if not os.path.exists(FILTERBANK):
        raise SystemExit(
            f"filterbank not found at {FILTERBANK}\nrun scripts/fetch-models.sh first")
    mel_fb = load_filterbank(FILTERBANK)
    samples = synth_waveform()
    mel, frames = linear_mel(samples, mel_fb)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    payload = {
        "sampleRate": SAMPLE_RATE,
        "nMels": N_MELS,
        "frames": frames,
        "samples": [round(float(x), 7) for x in samples],
        # mel-major [nMels][frames], the pre-log linear stage.
        "linearMel": [[float(mel[m, t]) for t in range(frames)] for m in range(N_MELS)],
    }
    with open(OUT, "w") as f:
        json.dump(payload, f)
    print(f"wrote {OUT}: {len(samples)} samples, mel [{N_MELS},{frames}]")
    print(f"  linear mel range [{mel.min():.4e}, {mel.max():.4e}]")


if __name__ == "__main__":
    main()
