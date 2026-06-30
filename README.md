<p align="center">
  <img src="docs/icon.png" width="120" alt="Šapat icon — Ш monogram">
</p>

<h1 align="center">Šapat</h1>

<p align="center">A native macOS menu-bar app that turns spoken Serbian into clear, structured, genuinely useful output — entirely on your Mac.</p>

<p align="center">
  <a href="https://github.com/pavstev/sapat/actions/workflows/ci.yml"><img src="https://github.com/pavstev/sapat/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/pavstev/sapat/releases/latest"><img src="https://img.shields.io/github/v/release/pavstev/sapat?sort=semver" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/pavstev/sapat" alt="MIT"></a>
</p>

---

Press `⌥⇧Space` (or click the menu-bar **Ш**), speak Serbian, and Šapat transcribes it
on-device with [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift), then runs your
words through a local **thinking pipeline** — clean, extract structure, recall your own past
notes, reason, self-critique, synthesize — and produces the artifact you asked for. Everything
runs on your Mac, with **no external services**.

> *Šapat* (шапат) is Serbian for "whisper" — a nod to the on-device Whisper engine. The
> icon is **Ш**, the Cyrillic letter that opens the word.

## What it does

Šapat is a local-first thinking workspace for a developer who brain-dumps long spoken
monologues and wants them turned into something useful — not just cleaned grammar.

```
record / import audio
   └─ WhisperKit large-v3 (Serbian, VAD)  ──▶  transcript     quiet pauses skipped
        └─ ThoughtPipeline (local LLM):
             1. Clean       de-dup, de-filler, formalize — the whole recording, never truncated
             2. Extract     intent, decisions, questions, action items, entities (typed, schema-constrained)
             3. Retrieve    your own related past notes from on-device semantic memory
             4. Reason      options, trade-offs, risks — grounded only in what you said
             5. Critique    a second pass that strips overclaims / anything ungrounded
             6. Synthesize  render the artifact for the selected Output Mode
   └─ show, auto-copy, save + index into memory
```

The whole pipeline keeps the original **no-fabrication** ethos: it works *only with what you
said*, states each idea once, and adds nothing — and a conservative sanitizer strips any model
scaffolding that leaks. Pure-refine modes (Polished English/Serbian) skip straight from Clean
to output, so the flagship translation is as fast and faithful as ever.

## Output Modes

Pick inline (no Settings screen) — each is a small pipeline config:

| Mode | What you get |
| --- | --- |
| **Polished English** | Your Serbian, cleaned and de-duplicated into one precise English statement (today's flagship behaviour, unchanged). |
| **Polished Serbian** | The same faithful cleanup, output in Serbian — not translated. |
| **Structured brief** | Intent, topics, decisions, open questions, action items, uncertainties. |
| **Engineering report** | A PR-style write-up: problem, approach, trade-offs, what was verified, risks. |
| **Prompt refiner** | A rambling monologue → one tight, self-contained prompt to paste into an AI assistant. |
| **Standup** | Yesterday / Today / Blockers, mapped from what you reported. |

## Features

- **On-device transcription** — WhisperKit `large-v3` with VAD silence handling, tuned for long, pause-heavy monologues. (large-v3 is kept deliberately over the faster "turbo" model for Serbian accuracy.)
- **Self-contained inference** — the reasoner runs **in-process via [MLX](https://github.com/ml-explore/mlx-swift)** on Apple Silicon. No other apps, no `lms` CLI, no localhost server. (LM Studio remains an optional opt-in backend.)
- **Persistent semantic memory** — past transcripts and artifacts are indexed locally (SQLite + FTS5 keyword + on-device embeddings, fused with Reciprocal Rank Fusion). The pipeline recalls your related prior context so it answers with your accumulated knowledge.
- **Whole-recording guarantee** — long transcripts that exceed the model's context are split on sentence boundaries, refined piece by piece, then merged + de-duped, so the **beginning is never silently dropped**.
- **Import any recording** — pick or drag in an audio **or video** file of any length; the audio track is extracted, silence skipped, transcribed + run through the pipeline like a live take.
- **Models managed, not re-downloaded** — model weights live in `~/Library/Application Support/Sapat/Models`, *outside* the app bundle, so an in-place update never wipes them and a multi-GB model is fetched once and reused across every release.
- **Concise history that keeps your recordings** — searchable, tap-to-expand rows. If a job fails, the entry is kept with its recording so you can **Retry** it; nothing said is lost.
- **Global hotkey** `⌥⇧Space` to start/stop; **Esc** cancels. The menu-bar **Ш** animates as a live waveform while recording. Quitting mid-job asks first.
- **Secure automatic updates** — checks GitHub Releases, downloads, **verifies a detached ed25519 signature** against a key embedded in the app (fail-closed — a tampered or unsigned build is refused), swaps the bundle in place, and relaunches.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/pavstev/sapat/main/scripts/install.sh | bash
```

Cleans up any prior install, downloads the latest release, verifies its checksum, strips the
Gatekeeper quarantine (it's **ad-hoc signed**, so a manual install needs `xattr -dr
com.apple.quarantine /Applications/Sapat.app`), installs to `/Applications`, and launches.
First launch downloads the speech + reasoner models (cached thereafter, outside the bundle) and
asks once for the microphone. Reset with `./scripts/cleanup.sh [--purge]`.

No external apps are required.

## Build from source

```sh
brew install xcodegen                          # one-time
git clone https://github.com/pavstev/sapat.git && cd sapat
./bundle.sh && open Sapat.app                  # xcodegen + xcodebuild + ad-hoc sign
```

`bundle.sh` builds with `xcodebuild` (the in-process **MLX** engine's Metal kernels need
Xcode's toolchain — first time: `xcodebuild -downloadComponent MetalToolchain`). It falls back
to `swift build` under the Command Line Tools, which compiles the engine-agnostic layers
(Inference, Pipeline, Memory, Updater) with MLX gated out via `#if canImport(MLXLLM)`. See
[AGENTS.md](AGENTS.md) for the engine wiring.

Overrides: `SAPAT_VERSION=1.2.3` stamps a version. Tests: `swift test` (the engine-agnostic
suite, 110 tests).

## Releasing

Tag-triggered and automated by [`release.yml`](.github/workflows/release.yml): `git tag
v1.3.0 && git push origin v1.3.0` builds, signs (ed25519), and publishes a GitHub Release the
in-app updater picks up. Signing uses the `SAPAT_SIGNING_KEY` repository secret; the matching
public key is embedded in [`ReleaseSignature.swift`](Sources/ReleaseSignature.swift). Every
push/PR to `main` is build-checked + tested by [`ci.yml`](.github/workflows/ci.yml).

## Project layout

| Path | Responsibility |
| --- | --- |
| `Sources/Brand.swift` | Single source of truth: name, bundle id, repo slug, on-disk paths |
| `Sources/Inference/` | `Inference` protocol; `Refiner` (Clean + whole-recording chunk/merge); `MLXInference` (default), `LMStudioInference` (opt-in) |
| `Sources/Pipeline/` | `ThoughtPipeline` (the staged "thinking"); `OutputMode` registry; `Extraction` (§6 schema) |
| `Sources/Memory/` | `MemoryStore` (GRDB + FTS5 + vector, RRF hybrid); `Embedder` (NaturalLanguage) |
| `Sources/Models/ModelStore.swift` | Self-managed, resumable, integrity-checked model downloads (outside the bundle) |
| `Sources/RecorderViewModel.swift` | `@Observable @MainActor` record → transcribe → pipeline flow |
| `Sources/WhisperEngine.swift` | WhisperKit wrapper, tuned for long-form VAD silence handling |
| `Sources/OutputSanitizer.swift` | Conservative scaffolding stripper (reused by the pipeline) |
| `Sources/HistoryStore.swift` · `HistoryView.swift` | JSON history (record of truth) + concise UI; indexes into memory |
| `Sources/PopoverView.swift` · `OutputModePicker.swift` · `Theme.swift` | SwiftUI popover, on-screen mode dropdown, copper-on-stone tokens |
| `Sources/UpdateChecker.swift` · `ReleaseSignature.swift` | Auto-updater + fail-closed ed25519 verification |
| `Sources/GlobalHotKey.swift` | Carbon `RegisterEventHotKey` wrapper (⌥⇧Space, permission-free) |
| `bundle.sh` · `scripts/` · `.github/workflows/` | Build/assemble, install/cleanup, release signing, CI |

## Notes

- First run downloads the WhisperKit speech model and the MLX reasoner model; both cached outside the bundle and reused across updates. Releases are ad-hoc signed, not notarized (a Developer ID notarization path is documented in `AGENTS.md`).
- Everything is local-only and private by default; raw audio/text never leaves the machine. An optional cloud backend exists for development and is **off by default**.
- Bundle id: `com.stevanpavlovic.Sapat`.

## Dependencies

- [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) — on-device speech (MIT)
- [MLX Swift](https://github.com/ml-explore/mlx-swift) + [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) — in-process local LLM on Apple Silicon (MIT)
- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite + FTS5 for semantic memory (MIT)
- A bundled/managed quantized reasoner model (Qwen3-class, MLX, Apache-2.0)

## License

[MIT](LICENSE) © Stevan Pavlović
