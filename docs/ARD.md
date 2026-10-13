# Piano Pals — Architecture & Decision Record

_Living document. Each decision lists the context and the alternatives rejected._

## 1. Module map
```
PianoPals/
  App/          PianoPalsApp, AppModel (wiring)
  Core/         Models (Note, Lesson, Finger), PianoGeometry, HostClock, Locked
  Lesson/       FingeringEngine, RawMusicParsers (note text + .mid), SongLibrary,
                AILessonGeneratorService (+ transports, local fallback), LessonSession (engine)
  MIDI/         MIDIParser (pure), MIDIManager (CoreMIDI)
  Camera/       CameraDevices, CameraChannel (1 AVCaptureSession each, or a remote iPhone), CameraHub, CameraPreviewView, PreviewEncoder
  Companion/    CompanionProtocol (wire + ClockSync), CompanionTransport (TLS-PSK, framing, Keychain), CompanionHost (iPhone), RemoteCameraLink (iPad), CompanionModel/RootView (iPhone UI)
  Coach/        MistakeAnalyzer, Coach, SessionSummary/ProgressStore
  Vision/       HandModels, HandPoseProcessor, FaceExpression, KeyboardRegion, FingerAttribution
  Calibration/  HandTemplate (+matcher), CalibrationFlow, CalibrationStore
  Audio/        ToneSynth, Narrator
  Views/        Child UI (home, songs, lesson, calibration), grown-ups panel
PianoPalsTests/ unit tests (engine, MIDI, vision geometry, session, calibration)
```

## 2. Data flow (key strike)
```
USB MIDI keyboard ─► MIDIManager ─ NoteEvent(hostTime) ─┐
On-screen key ─────► MIDIManager.injectOnScreen ────────┤
                                                        ▼
Camera ─► CameraChannel ─► HandPoseProcessor ─► HandFrameHistory (ring buffer, host-time stamped)
                                                        │ wait ≤120 ms for a frame at/after the strike
                                                        ▼
                                  FingerAttributor(note, frame, KeyboardRegion) ─► DetectedFinger?
                                                        ▼
                                        LessonSession.handleNoteOn ─► SessionEvent
                                                        ▼
                         Avatar mood · Confetti · Key pulse · Narrator · progress/stars
```

## 3. Decisions
**D1 — ~~Continuity Camera~~ → iPhone camera mode (corrected 2026-10-13).** The original plan assumed iPadOS surfaces a nearby iPhone via `AVCaptureDevice.DiscoverySession(.continuityCamera)`. On a real iPad Pro the overhead channel stayed `noCamera` with the iPhone nearby, and Apple's Continuity requirements list iPhone-as-webcam for Mac and iPhone/iPad-as-webcam for Apple TV only. `AVContinuityDevicePickerViewController` is tvOS-only. **Replaced by D15.** USB-C UVC webcams (`.external`) remain supported.

**D2 — `.external` / `.continuityCamera`, not `.externalUnknown`.** `.externalUnknown` is macOS-only (unavailable on iOS).

**D3 — One `AVCaptureSession` per channel, not `AVCaptureMultiCamSession`.** Multi-cam cannot include a Continuity/external camera. Consequence: only **one built-in iPad camera** can run at once; the second channel is the iPhone/external camera. The hub enforces this.

**D4 — Upright buffers, then Vision with `.up`.** The capture connection rotates/mirrors pixels (via `AVCaptureDevice.RotationCoordinator` + manual offset), so Vision output is already in display space and overlay math is linear. Handedness is swapped back when the picture is mirrored. Camera tiles are sized to the video aspect ratio so no crop distorts the overlay.

**D5 — Vision per channel on that channel's serial queue with late-frame discarding.** Natural back-pressure; two cameras process concurrently; UI publishes at ≤30 Hz.

**D6 — Shared host clock.** MIDI packet timestamps, `CACurrentMediaTime`, and `CMSampleBuffer` PTS share the mach host clock, so a strike can be matched to the nearest video frame. Attribution waits up to ~120 ms for the frame to arrive (processing latency).

**D7 — Keyboard mapping is a 1-D linear fit (`KeyboardRegion`).** Calibration (right-hand C position, left-hand C position) gives ≥10 fingertip↔key pairs; least squares yields white-keys-per-image-width and offset. Sign of the slope handles reversed cameras. Chosen over homography because depth/perspective from a single camera is unreliable and tolerance is ±1 key. Sanity checks reject nonsense fits.

**D8 — Lenient judging.** If the camera can't confidently see a finger, the note still counts (`fingerUnverified`). A wrong finger on the right key advances with a softer reaction and a hint. Wrong keys never subtract anything. Rationale: 5-year-olds; vision error would otherwise feel like the app is wrong.

**D9 — "Wait for me" pacing by default.** The clock stops at the next unplayed note; "Play along" is available for older/faster players. Falling-note drawing reads `songTime(at:)` per frame instead of publishing a clock, so SwiftUI isn't invalidated 60×/s.

**D10 — Fingering by Viterbi search.** Costs encode one-finger-per-key position play, direction, stretch, thumb-on-black, leaps. Unit tests lock in textbook results (C–G scale 1-2-3-4-5, Ode to Joy 3-3-4-5-5-4-3-2-1-1-2-3-3-2-2).

**D11 — Cloud pipeline behind a transport protocol.** `LessonTransport` is mockable; the service validates and times out; every failure routes to the on-device engine. Unknown songs become clearly-labelled *practice tunes* (never pretends to be the real song).

**D12 — Face expression via Vision landmarks, not ARKit.** `ARFaceTrackingConfiguration` takes exclusive use of the TrueDepth camera and would block the front-camera video/hand tracking. Landmark-based smile score is coarse but sufficient for avatar mirroring.

**D13 — Swift 5 language mode, iOS 17 deployment target.** Avoids Swift 6 strict-concurrency friction with AVFoundation/CoreMIDI callbacks; shared mutable state is wrapped in `Locked`. Revisit once on a Swift 6 migration.

**D15 — iPhone camera mode over an encrypted local link.** The same app on an iPhone shows a camera screen: the iPhone runs Vision hand pose itself and sends only landmarks (+ a ≤ 60 KB JPEG preview at ~10 fps) to the iPad. Transport: Bonjour (`_pianopals-cam._tcp`) + Network.framework TCP with **TLS 1.2 PSK (AES-128-GCM)** derived from an 8-digit pairing code shown on the iPhone, so nothing without the code can connect and traffic is encrypted; codes are stored in the Keychain on both sides and the iPad reconnects automatically. Length-prefixed JSON messages; droppable frames are skipped when > 3 sends are queued (latency over completeness). ClockSync (12 quick pings then 1 Hz, lowest-RTT sample wins) maps iPhone frame times onto the iPad host clock so a key strike and the hand frame it landed in can be compared. *Rejected:* MultipeerConnectivity (could not be verified between simulators; the in-process encrypted loopback test is possible with Network.framework), streaming video to the iPad (privacy, bandwidth, latency), Continuity Camera (unsupported, D1).

**D16 — Local-model calls never sit on the critical path.** Apple's on-device model is only consulted after the deterministic matcher misses, with a hard timeout implemented so it returns even if the model call ignores cancellation (a task group would wait for it — this caused a real hang found in testing).

**D14 — Project uses Xcode synchronized folders (objectVersion 77).** New Swift files are picked up automatically; no per-file project edits.

## 4. Risks
| Risk | Mitigation | Status |
|---|---|---|
| Vision hand pose weak on small child hands / overhead angle | Generous template tolerance; lenient judging; manual rotate/flip | needs device test |
| Continuity Camera availability on iPad (OS, Wi-Fi/BT, same Apple ID, iPhone orientation) | Live-refreshing picker with troubleshooting text | needs device test |
| Camera latency vs. MIDI | Host-clock matching + 120 ms wait | needs device test |
| Two cameras + Vision thermal load | 30/60 fps preference, late-frame dropping | needs device test |
| No real AI backend | Mock + fallback; transport ready | open |

## 5. Change log
* 2026-10-13 — Engine layers, tests, PRD/ARD created.
* 2026-10-13 — Child-friendly UI built; verified in iPad simulator (home, songs, lesson, calibration with demo hands, grown-ups, finish card). 94 unit + 7 UI tests green. Bugs found and fixed through testing: tempo/mode change re-anchored with the *new* value (notes jumped); fingering allowed different fingers on a repeated note; Simulator showed a spurious "camera failed" state; calibration hand-print rendered as a blob.
* 2026-10-13 — AI phase: song index + fuzzy matcher, honest not-found, listen mode (YIN), mistake analyzer, coach, progress, hand smoothing, majority-vote finger attribution, latency metrics (see PRD_AI_COACH.md). Bugs found by testing: spurious "Making your song…" spinner (Grown-ups view wasn't observing the model), timeout that waited for an uncancellable model call, repeated notes merged by the segmenter, pitch detector too slow in debug builds.
* 2026-10-13 — Real-iPad test showed Continuity Camera is unavailable to apps → D1 corrected, iPhone camera mode built (D15).
* Added Debug-only launch arguments (`-debugScreen`, `-debugSong`, `-debugAutostart`, `-debugPlay`, `-demoHands`) for deterministic screenshots/tests. They compile out of Release.

## 6. Verification status
| Area | Verified how | Result |
|---|---|---|
| Fingering, parsers, service/fallback, session, calibration math, MIDI parsing, keyboard fit, attribution, face heuristic | 94 unit tests | pass |
| Navigation, key taps, song completion, wrong-key tolerance, pause/resume, calibration (demo), gate, lesson generation | 7 XCUITests, real touches, iPad Pro 13" (M4) simulator | pass |
| Visuals | Simulator screenshots | reviewed |
| Live camera, Vision on real hands, Continuity Camera, two cameras at once, USB MIDI, audio, speech | **not possible in Simulator** | pending device test (`docs/TEST_PLAN.md`) |
