# Sortformer (Core AI) — model provenance & re-export handoff

**Status: WORKING via a locally re-exported model.** The HF-published conversion
(`mlboydaisuke/Streaming-Sortformer-Diar-CoreAI`) does **not** load on the current toolchain;
the model shipping on this machine was **re-exported locally from the NVIDIA checkpoint with
the current public Core AI stack** and passes every gate: it loads clean, clears the ≥85%
ground-truth attribution gate on both clips, agrees with SpeakerKit, and runs ~66× realtime on
the M4. `DiarizationBackend.default == .sortformer`; SpeakerKit is the independent A/B
cross-check and the fallback when the model isn't provisioned.

This file documents why the HF original fails and how to regenerate the re-export on a fresh
machine (the artifact is a local product — it is not in git and not on HF).

## Why the HF original fails (exact symptom)

Loading the HF `sortformer_float16.aimodel` via `AIModel(contentsOf:options:)` aborts the
process during graph specialization:

```
loc(...LayerNorm$121 / ... / export_sortformer.py:42 ...):
  error: expected AICode versioned location, got: loc(...)
error: Failed to convert to versioned IR
LLVM ERROR: cannot unwrap empty `odiec_module_t`
```

- Compute-unit independent (`.gpu`/`.cpu`), wrapper independent (raw `CoreAI` framework,
  coreai-kit `GraphModel`, and the public `coreai-core` Python runtime all abort identically).
- The abort is **fatal and uncatchable** — a load can never be used as a fallible probe, which
  is why the real-model tests are env-gated (`SORTFORMER_MODEL_OK=1`), not auto-detected.
- The bundle is intact (`AIModelAsset.summary()` → `functions: ["main"]`; sizes match HF) —
  the block is stale IR, not corruption: the export was made on an internal/dev toolchain
  whose debug-info fused-location metadata predates the current versioned-location scheme;
  the `ConvertDebugInfoToVersionedLocations` pass rejects it.
- AOT does not rescue that file: the correct AOT invocation is `xcrun coreai-build compile`
  (the Metal-toolchain-bundled binary — `xcrun aimodelc`'s "requires the Metal Toolchain"
  error is a detection-bug decoy), but the versioned-IR pass runs there too.

## Regenerating the re-export (proven recipe, ~15 min)

1. Python **3.10–3.13** venv (3.14 makes pip silently exclude all coreai wheels):
   `pip install coreai-torch` (0.4.1, pins `coreai-core==1.0.0b2`) + `torch` + `numpy`.
2. Clone `github.com/apple/coreai-models` (BSD-3), `pip install --no-deps -e` it.
3. Download `nvidia/diar_streaming_sortformer_4spk-v2` (.nemo, CC-BY-4.0, ~471MB) from HF;
   extract `model_weights.ckpt`.
4. Drive the export with the zoo recipe (`/tmp/coreai-model-zoo/conversion/sortformer_diar/`,
   or the adapted driver preserved at `/tmp/sortformer-reexport/export_reexport.py`). Two
   known API drifts vs the zoo's `export_sortformer.py`: current `export_to_coreai` has no
   `externalize_modules` param, and `save_asset` needs a `Path` (not `str`). Export takes ~11s.
5. Verify: `xcrun coreai-build compile <m>.aimodel --output /tmp/x --platform macOS` (must
   pass all arch targets), then a **subprocess** Swift load test (exit 0, `LOAD_OK`).
6. Stage into `~/Library/Application Support/TranscriptionStudio/Models/`:
   `sortformer_float16.aimodel` + **`sortformer_manifest.json`** with the new `main.mlirb`
   byte size and sha256 — the manifest name/schema is `SortformerModelStore`'s contract
   (`{"files":[{"name":...,"bytes":...,"sha256":...}]}`). Without it the store falls back to
   HF-original sizes, fails verification, and **re-downloads the broken HF model over yours**.
7. Prove it end to end: `TEST_RUNNER_SORTFORMER_MODEL_OK=1 xcodebuild -project
   TranscriptionStudio.xcodeproj -scheme TranscriptionStudio
   -destination 'platform=macOS,arch=arm64' test
   -only-testing:TranscriptionStudioTests/SortformerRealModelTests`.

Current staged artifact: exported 2026-07-09 (coreai-torch 0.4.1), `main.mlirb` =
236,887,041 bytes, sha256 `71a8098…4b0843`; eager-PyTorch vs exported-graph cosine 0.9999
on both chunk paths. Provenance: `reexport-provenance.json` next to the artifacts. The HF
originals are kept as `sortformer_float16.aimodel.hf-orig` / `.hf-redownload`.

## Environment note

The **Metal Toolchain** (27A5218h) was installed for Core AI AOT work
(`xcodebuild -downloadComponent metalToolchain`) — needed by `coreai-build compile` and
on-device graph specialization.
