# Piano Pals — Functional Requirements Tracker

Single source of truth for **what we committed to** and **where each item stands**. Detail and success metrics live in the PRDs;
this page is the index. Rule of work: *only build things listed here. A new idea gets a row first (marked NEW), then code.*

Status: ✅ done & verified · 🟡 built, needs real-world check (device / hardware / child) · ⬜ not started · ⛔ blocked on user input

Last updated: 2026-10-14

Live board (cards, owner, progress log): https://claude.ai/artifact/JdcUVmY8p43DXki6A1Yauk — kept in step with this page after every commit.

## A. Core (PRD.md — v1 brief)

| ID | Requirement | Status | Notes |
|---|---|---|---|
| CAM-1 | Built-in iPad camera | 🟡 | working on user's iPad |
| CAM-2/3 | Second camera = iPhone in camera mode (encrypted local link, pairing code) | 🟡 | works with user's iPhone; retest needs both unlocked |
| CAM-4 | Grid / picture-in-picture, swap | ✅ | superseded in lesson by camera-on-top layout (A1) |
| CAM-5/6 | Independent sessions, 60 fps, rotate/flip | 🟡 | |
| VIS-1…5 | Hand pose, 21 landmarks, keyboard-normalised, finger attribution, overlay | ✅ / 🟡 live | |
| MID-1…3 | CoreMIDI (1.0 + UMP 2.0), shared clock | ✅ / 🟡 real keyboard | Impact LX61+ |
| LES-1…5 | Input → lesson, mockable service, on-device fingering, validation | ✅ | |
| KID-1…8 | Colour+shape fingers, big buttons, avatar, confetti, gentle feedback, lane, calibration, grown-ups gate | ✅ / 🟡 | |

## B. AI coach (PRD_AI_COACH.md — v2)

| ID | Requirement | Status |
|---|---|---|
| F1 | Bundled licence-tagged song index (18 songs) | ✅ |
| F2 | Offline fuzzy matching | ✅ |
| F3 | YouTube/share link → title → match | ✅ |
| F4 | Honest not-found | ✅ |
| F5 | On-device title cleanup | ✅ |
| F6 | Listen mode (YIN) | ✅ / 🟡 real playing |
| F7 | Mistake analyzer | ✅ |
| F8 | Coach (rate-limited, adaptive) | ✅ |
| F9 | Parent progress | ✅ |
| F10 | Camera accuracy pass | ✅ / 🟡 live |
| F11 | iPhone camera mode | 🟡 |
| M1–M11, C1–C6 | Metrics verified by unit/loopback tests | ✅ |
| M12, C7, D1–D9 | Privacy review, discovery, latency, child trials | 🟡 need real-world sessions |

## C. Practice, layout, transcription (PRD_V3_PRACTICE_AND_TRANSCRIBE.md — v3)

| ID | Requirement | Status | Notes |
|---|---|---|---|
| F12 / L1–L5 | Camera on top, lesson below, keyboard ≥ 90 % width, wrong-finger ring + arrow, target marker | ✅ | UI-tested; visual check with demo hands |
| A1 | Camera strip lined up with on-screen keys (crop + mirror from calibration) | ✅ | `CameraAlignment`; real-camera check 🟡 |
| A2 | Footage optional (stylised keys only) | ✅ | Grown-ups toggle |
| A3 | iPhone camera overlay mapping correct (aspect fit) | ✅ | |
| K61 | Tuned for 61-key board (C2–C7), never shows keys it lacks | ✅ | |
| **P1 (NEW, asked 2026-10-14)** | **Keyboard window pans by whole octaves to follow the music** | ✅ code + 6 unit tests · 🟡 on-device look | `SpanFollower`; lane, keys, strip share one span |
| F13 / E1–E5 | Beginner exercises, scales RH/LH, daily practice block | ✅ E1–E5 (UI-tested) | |
| F14 / W1–W6 | Search the web (Mutopia, Wikimedia Commons) for grown-ups, licence-gated, convert to lesson | ✅ W1–W4, W6 (unit + UI tests) · W5 live: 10/10 titles had ≥1 open-licence MIDI; end-to-end add of “Ode to Joy” verified in simulator | `OnlineMelodySearch.swift`; explicit button, licence badges |
| F15 / T1–T6 | On-device audio → notes (Basic Pitch Core ML + YIN fallback) | ✅ T1–T4, T6 (simulator 0.19 s for 30 s; device timing 🟡) · 🟡 T5 real piano clip still needed | `Transcribe/`; Basic Pitch Core ML (Apache-2.0, 270 KB, bundled); end-to-end verified in simulator |
| F16 (from board) | What "AI-MIDI / Songscription / YouTube-to-MIDI" tools take and what is free | ✅ write-up: `docs/PRD_V4_SEARCH_AND_CONVERT.md` | on-device F15 already covers the free part; YouTube audio extraction not done (YouTube terms) |
| F17 (from board) | Browser-like song search for grown-ups: type a song, watch 4 steps tick (your songs, free library, Apple + MusicBrainz catalogue, open files), pick "this one" with artwork + 30 s preview, then a "what we can do" card (library / open file / your recording / play it / practice tune) | ✅ built: `Lesson/CatalogSearch.swift`, `Views/SongSearchView.swift`; 278 unit tests + UI test pass; live check in simulator (Adele result with artwork) · 🟡 try on the iPad | words sent to Apple + MusicBrainz approved by user 2026-10-14; YouTube-to-MP3 deliberately not built (YouTube terms, App Store rule 5.2.3) |
| F18 (NEW, asked on board) | "Listen for 30 s, then transcribe with Basic Pitch": play a song on another device, the iPad listens with its microphone and handles chords/bass (today's Listen follows one note at a time) | ⬜ proposed, waiting for the user's yes | cannot capture another app's audio on iPadOS; sound analysed in memory, never saved |
| BUG: black screen on iPad | Piano Pals shows a black window in the app switcher on the iPad | 🟡 investigating: no crash report, camera daemon crashed 17:22, needs the user's Xcode pause stack | see board |
| A4 (from board) | ONE wide camera view edge to edge, iPhone camera first, pinch to zoom / drag to pan / double-tap reset (replaces the two-tile band; old Layout setting and CameraBand removed) | ✅ built, simulator-checked, tests pass · 🟡 gestures + real iPhone picture need a try on the iPad | `Views/PanZoomView.swift`, `LessonView.unalignedBand` |
| BUG: no sound (from board) | Real MIDI keyboard made no sound: "sound for the real keyboard" defaulted to off, but the Impact LX61+ has no speakers | ✅ default now on; 2 tests · 🟡 confirm on the iPad (volume, silent switch is ignored by the app) | `AppSettings.hardwareSound` |
| MAC | Runs on Mac (Catalyst) | 🟡 | builds & tests pass; user hasn't looked yet |

## D. Order of work (don't skip ahead)

1. ~~P1 panning~~ done
2. ~~E5 / L-series UI tests~~ done
3. ~~F14 web search (W1–W6)~~ done
4. ~~F15 transcription~~ built; T5 waits for a real piano clip, T6 for a device run
5. Real-world checks (D1–D9, iPhone link retest, Mac look)

Anything not in this table is out of scope until added here.
