# Sortformer (Core AI) — load status & re-export handoff

**Status (2026-07-09): the Sortformer diarizer's neural core does NOT load on the current
toolchain.** The full Swift port is complete and unit-verified independently of the model (mel
golden gate + AOSC synthetic gates pass); only the live forward pass is blocked. **SpeakerKit
(Pyannote/CoreML) is the shipping default diarizer** and passes the ≥85% ground-truth attribution
gate for real. The Sortformer path lights up the moment a re-exported model loads — the swap is
one line (`DiarizationBackend.default`) plus flipping the env flag on the real-model test.

## Symptom (exact)

Loading `sortformer_float16.aimodel` via `AIModel(contentsOf:options:)` (GPU +
`expectFrequentReshapes`) aborts the process during graph specialization:

```
loc(...LayerNorm$121 / TFEncoderBlock$18 / ... / export_sortformer.py:42 ...):
  error: expected AICode versioned location, got: loc(...)
loc(...): error: Failed to convert to versioned IR
LLVM ERROR: cannot unwrap empty `odiec_module_t`
```

Reproduced on **macOS 26A5378j, Xcode 27A5218g, Apple M4**, and:

- **compute-unit independent** — same abort on `.gpu` and `.cpu`.
- **wrapper independent** — identical abort via the raw `CoreAI` framework (`AIModel`), via
  coreai-kit's `GraphModel`, and (per the unblock lane) via the **public `coreai-core` Python
  runtime**. Not an Xcode-beta artifact.
- The failure is a **fatal, uncatchable `abort()`** — it cannot be caught as a Swift error, so the
  runner MUST NOT attempt the load as a fallible probe. This is why the real-model test is env-gated
  (`SORTFORMER_MODEL_OK=1`), not auto-detected.

## Root cause

The HF-published `.aimodel` was exported on an Apple engineer's **internal/dev Core AI toolchain
build**. Its MLIR carries **debug-info fused-location metadata that predates the current
versioned-location scheme**, and the `ConvertDebugInfoToVersionedLocations` pass aborts on it. **No
load flag escapes it** — it is a property of the serialized model, not of how it's loaded.

## The bundle itself is intact (not a partial/poisoned file)

- `AIModelAsset(contentsOf:).summary()` **succeeds** → `functions: ["main"]`.
- `main.mlirb` is exactly **236655368** bytes (the HF original; matched byte-for-byte against the
  live HF `x-linked-size`, repo last-modified 2026-07-06). The mel filterbank is 131584 bytes.
- So the block is purely the stale-IR incompatibility above — the model is well-formed, just
  exported by an older IR emitter.

## What unblocks it

1. **Re-export the model against the current public toolchain** (coreai-torch / coreai-core + the
   NVIDIA `diar_streaming_sortformer_4spk-v2` checkpoint, CC-BY-4.0). This is the real fix and is
   **in progress in a separate lane**. A freshly-exported `sortformer_float16.aimodel` dropped into
   `~/Library/Application Support/TranscriptionStudio/Models/` is picked up automatically —
   `SortformerModelStore` is **manifest-driven** and treats a locally-provisioned model as
   first-class (no HF re-download; a re-export writes its own `sortformer_manifest.json` with the new
   size, which WILL differ from 236655368).
2. **AOT compile** (`xcrun coreai-build compile <m>.aimodel --output <m>.aimodelc`) — the correct AOT
   invocation is `coreai-build` (the Metal-toolchain-bundled binary), **not** `xcrun aimodelc`, whose
   "Core AI requires the Metal Toolchain" gate is a **detection-bug decoy** (it fires even with the
   Metal Toolchain installed). **However, AOT does not rescue THIS file** — the versioned-IR pass
   runs in the AOT path too and hits the same abort. AOT only helps once the model is re-exported
   from a current toolchain.

## How to light it up after a re-export

1. Drop the re-exported `sortformer_float16.aimodel` (+ its `sortformer_manifest.json`) into the
   Models directory.
2. Verify it loads: `SORTFORMER_MODEL_OK=1 swift test --filter SortformerRealModelTests` — this runs
   the attribution gate through the real model on both clips and cross-checks against SpeakerKit.
3. If green, flip `DiarizationBackend.default` to `.sortformer` (streaming diarization; SpeakerKit
   remains the A/B cross-check and the iOS graceful-degradation fallback).

## Environment note

The **Metal Toolchain (27A5218h)** was installed during this investigation
(`xcodebuild -downloadComponent metalToolchain`). It is required for any Core AI AOT compilation
(`coreai-build compile`) and for on-device Core AI graph specialization. Registered in
`setup/REBUILD.md` for the parent workspace if the AOT path is adopted.
