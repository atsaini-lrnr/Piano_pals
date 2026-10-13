# Piano Pals — PRD v2: Song Intelligence & Local AI Coach

_Companion to `PRD.md` (v1 = camera, MIDI, kid UI). This document owns the **success metrics** for the AI work.
Status is updated at the end of every phase. Last updated: 2026-10-13._

## 1. Problem
v1 can play built-in songs, but (a) a grown-up who pastes a link or title mostly gets a made-up *practice tune*, not the
song, and (b) the app only reacts to mistakes with a colour pulse — it doesn't **coach**. v2 fixes both, **entirely on-device**
(no cloud LLM; video and audio never leave the iPad).

## 2. Principles (non-negotiable)
1. **Local only.** No cloud language model. Network is limited to (a) the YouTube *title* lookup (video ID only) and (b) an optional, off-by-default lesson endpoint. No audio/video upload, ever.
2. **Never fake a song.** If we can't find it we say so and offer real alternatives; a practice tune is an explicit opt-in.
3. **Detection is code, wording is optional AI.** Mistakes are detected deterministically in microseconds; an on-device model may only *phrase* parent summaries, after play, with templates as fallback.
4. **Never negative to the child.** No red, no error sound, no negative words (enforced by test).
5. **Free and licence-clean.** Only public-domain / CC0 melodies are bundled; each carries its licence.

## 3. Scope
| # | Feature | Summary |
|---|---|---|
| F1 | Song index | Bundled, licence-tagged JSON index of public-domain melodies (+ a build tool to extend it from Mutopia/PDMX/OpenScore downloads) |
| F2 | Song matching | Offline fuzzy search: typos, noisy YouTube titles, composer-only queries; no false matches |
| F3 | YouTube/share lookup | Title read via oEmbed (title only) → matched against the index |
| F4 | Honest not-found | Suggestions + "Listen", "Import MIDI", "Practice tune anyway" |
| F5 | On-device title cleanup | Rule-based always; Apple on-device model when available |
| F6 | Listen mode | Parent plays/hums a tune; on-device pitch tracking (YIN) → notes → fingered lesson |
| F7 | Mistake analyzer | Classifies wrong key / finger / hand / hesitation / skipped note; per-finger stats |
| F8 | Coach | Gentle, escalating, rate-limited hints; adaptive pace; spoken + visual |
| F9 | Parent progress | Per-session summary (templates; Apple on-device model phrasing when available), stored locally |
| F10 | Camera accuracy pass | Joint smoothing + multi-frame finger voting + measured latency / verified-finger rate |

## 4. Success metrics
Legend: ✅ met & automatically verified · 🟡 built, **needs on-device measurement** · ⬜ not yet

### 4.1 Correctness (automatic, in CI)
| ID | Metric | Target | How measured | Status |
|---|---|---|---|---|
| M1 | Mistake classification accuracy on labelled corpus | 100 % | Unit tests over every `MistakeKind` incl. edge cases | ⬜ |
| M2 | Banned/negative words in anything the coach can say | 0 | Test scans all phrase pools against a banned list | ⬜ |
| M3 | Song-match top-1 accuracy on ≥ 60 query variants (typos, noisy titles, aliases, composer-only) | ≥ 95 % | Unit test | ⬜ |
| M4 | False-match rate on ≥ 20 unknown titles | 0 % | Unit test | ⬜ |
| M5 | Every bundled song: valid notation, in piano range, licence field set, fingers 1–5 | 100 % | Unit test | ⬜ |
| M6 | Listen mode: pitch error | ≤ 25 cents, 80–1000 Hz | Synthetic tones incl. harmonics + vibrato | ⬜ |
| M7 | Listen mode: note-level F1 on synthetic monophonic melodies | ≥ 0.95 | Unit test | ⬜ |
| M8 | Listen mode: silence / noise produces no notes | 0 notes | Unit test | ⬜ |
| M9 | Joint smoothing: jitter reduction at rest | ≥ 50 % lower σ | Unit test | ⬜ |
| M10 | Multi-frame voting beats a single noisy frame | outvotes outlier | Unit test | ⬜ |
| M11 | Coach rate limit | ≤ 1 spoken tip / 6 s | Unit test | ⬜ |
| M12 | Privacy: no media leaves device | 0 uploads | Code review: only `YouTubeOEmbedFetcher` and the optional endpoint use `URLSession` | ⬜ |

### 4.2 On-device (measured by you; the app shows the numbers in Grown-ups ▸ Diagnostics)
| ID | Metric | Target | How measured | Status |
|---|---|---|---|---|
| D1 | Key-press → visual feedback (p95) | ≤ 150 ms | `LatencyMeter` (MIDI timestamp → feedback) | 🟡 |
| D2 | Hand tracking rate | ≥ 30 fps (60 target) | Diagnostics fps | 🟡 |
| D3 | Notes whose finger was verified by camera | ≥ 80 % in good light | Diagnostics "finger verified" | 🟡 |
| D4 | Wrong-finger false alarms (told "wrong finger" while correct) | ≤ 5 % | Manual test with a grown-up using known fingerings | 🟡 |
| D5 | Child completes a 14-note song unaided | ≥ 80 % of tested children | Observed sessions | 🟡 |
| D6 | Coach tips judged helpful, never upsetting | 0 distress events in sessions | Observed sessions | 🟡 |
| D7 | Listen mode on a real hummed/played tune: correct notes | ≥ 80 % for simple tunes | Manual | 🟡 |
| D8 | Battery/thermal: 20-min session, no thermal warning | pass | Manual | 🟡 |

## 5. Functional requirements and acceptance
**F1** Index ≥ 18 licence-tagged songs bundled; `tools/build_song_index.py` converts a folder of `.mid` + licence manifest into index JSON (tested).
**F2** `SongMatcher` returns ranked matches with scores; threshold rejects unrelated text.
**F3** YouTube link → title via `https://www.youtube.com/oembed` (only the video URL is sent); failure falls to not-found with a clear reason.
**F4** Not-found card lists up to 3 close suggestions and 3 actions; nothing is auto-invented.
**F5** `TitleNormalizer` strips noise ("Official Video", "Lyrics", "Piano Tutorial", brackets…); `OnDeviceTitleCleaner` uses Apple's Foundation Models when `SystemLanguageModel.default.availability == .available`, else is skipped.
**F6** Microphone permission with plain-language reason; live note display; Stop → lesson; audio not stored.
**F7/F8** Coach rules in `ARD.md` §Coach; adaptive: ≥ 4 consecutive wrong keys or ≥ 6 errors in last 10 attempts → switch to "Wait for me" / slow down 15 %.
**F9** Summary after each lesson: first-try accuracy, finger accuracy, weakest finger, stars, minutes. Stored locally (last 30). Parent sees it in Grown-ups ▸ Progress.
**F10** One-Euro filter per joint; finger attribution votes over ≈ 150 ms of frames; latency and verified-rate shown in Diagnostics.

## 5b. Proposed (not yet built — need your decision)
| # | Feature | Notes |
|---|---|---|
| P1 | **Posture coaching with Apple's body-pose model** (`VNDetectHumanBodyPoseRequest`) | Deterministic Apple framework, on-device. Detects slouching / raised shoulders / collapsed wrists from the side camera; also helps assign left/right when only part of a hand is visible. Does not replace hand pose for fingers. |
| P2 | **"What song is this?" with ShazamKit** | Identifies a song playing in the room → title → matched against the free library. **Gives a title only, never notes.** Needs the ShazamKit App Service capability on your App ID and network; a *signature* (fingerprint), not the raw audio, goes to Apple → must be an explicit per-use opt-in to respect principle 1. |
| — | Video encode/decode | **Not needed.** The app never records or stores video; it reads live frames only (AVFoundation). No model involved. |

## 6. Out of scope / honest limits
* Bundled songs are public-domain tunes transcribed from the tradition; **please report any wrong note** (they can't be checked against a score by me).
* Modern pop melodies are copyrighted: there's no free legal database. Listen mode and MIDI import are the legal routes.
* Listen mode is monophonic (one note at a time). Polyphonic audio needs a model such as Basic Pitch (Core ML) — deferred until its licence is confirmed.
* Audio-from-YouTube transcription is excluded (YouTube terms of service; copyright).
* No LLM is used for detection. Apple's on-device model is untestable in the Simulator; the template fallback is what the automated tests cover.

## 7. Phases
A — PRD, song index, matcher, title tools, honest not-found · B — analyzer, coach, progress · C — Listen mode, camera accuracy, metrics instrumentation · D — integration, screenshots, final test run, docs.
