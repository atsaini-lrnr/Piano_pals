# Piano Pals — Product Requirements Document

_Living document. Status column is updated as work lands. Last updated: 2026-10-13._

## 1. Summary
Piano Pals is a free iPadOS app (target: iPad Pro M4, landscape) that acts as an AI-assisted piano teacher for a
**5-year-old**. A camera watches the child's hands on a real keyboard, a USB-C MIDI keyboard supplies the notes, and the
screen shows which finger to use with bright colours, shapes and numbers, falling notes, a cartoon friend, and
celebrations. Nothing is ever punishing: wrong keys get a soft pulse, never a red flash or an error sound.

## 2. Users
| User | Needs |
|---|---|
| Child (≈5 yrs, pre-reader) | Huge tap targets, colour/shape cues instead of notation, instant positive feedback, spoken prompts |
| Parent / grown-up | Add songs (YouTube link, music-share text, title/composer), pick cameras, see MIDI status, recalibrate |

## 3. Goals / non-goals
**Goals:** correct finger guidance per note; works with a physical MIDI keyboard; two camera angles (iPad + nearby iPhone);
child-safe, encouraging UX; all processing on-device (video never leaves the iPad).
**Non-goals (v1):** reading sheet music, scoring rhythm strictly, accounts/cloud sync, in-app purchases, ads, analytics.

## 4. Functional requirements and status
Legend: ✅ done & unit-tested · 🟡 done, needs on-device verification · ⬜ not started

### 4.1 Dual-camera system
| ID | Requirement | Status |
|---|---|---|
| CAM-1 | Channel 1: built-in iPad camera (front/ultra-wide/back selectable) | 🟡 |
| CAM-2 | Channel 2: nearby iPhone via Continuity Camera / external camera discovery (`.continuityCamera`, `.external`) | 🟡 |
| CAM-3 | Easy way to pick the iPhone: in-app camera picker sheet (replaces `AVContinuityDevicePickerViewController`, which is tvOS-only) | ⬜ |
| CAM-4 | Grid and picture-in-picture layouts; swap which is large | ⬜ |
| CAM-5 | Independent sessions/queues per camera; interruption + disconnect handling; 30/60 fps format selection | 🟡 |
| CAM-6 | Manual rotate/flip per camera (overhead mounts) | 🟡 (UI ⬜) |

### 4.2 Hand pose & mapping
| ID | Requirement | Status |
|---|---|---|
| VIS-1 | `VNDetectHumanHandPoseRequest`, up to 2 hands, per-camera concurrent processing | 🟡 |
| VIS-2 | All 21 landmarks extracted; 5 fingertips used for key logic | ✅ (model) / 🟡 (live) |
| VIS-3 | Coordinates normalised into a keyboard bounding box (`KeyboardRegion`) | ✅ |
| VIS-4 | Fingertip → struck-key attribution at MIDI timestamp | ✅ |
| VIS-5 | Overlay: coloured circles + numbers 1–5 at fingertips | ⬜ |

### 4.3 MIDI
| ID | Requirement | Status |
|---|---|---|
| MID-1 | `MIDIManager: ObservableObject`, auto-discover + hot-plug USB-C sources | ✅ (no-hardware) / 🟡 (real keyboard) |
| MID-2 | Parse Note-On/Off (MIDI 1.0 and MIDI 2.0 UMP; velocity-0 = off) | ✅ |
| MID-3 | Timestamps on the same clock as camera frames | ✅ |

### 4.4 Lesson generation
| ID | Requirement | Status |
|---|---|---|
| LES-1 | Input field: YouTube link / music-share text / title-composer / raw note text | ⬜ UI, ✅ logic |
| LES-2 | `AILessonGeneratorService` with mockable transport; returns `Note{timestamp,duration,noteNumber,assignedFinger}` | ✅ |
| LES-3 | Real HTTPS transport ready to point at an endpoint | ✅ (untested against a server — none exists yet) |
| LES-4 | On-device fallback: logical fingering for any raw notes; MIDI-file import; built-in songs | ✅ |
| LES-5 | Validation + timeout; every failure falls back rather than erroring to the child | ✅ |

### 4.5 Child-friendly experience
| ID | Requirement | Status |
|---|---|---|
| KID-1 | Finger = colour + shape (Thumb red star, Index blue circle, Middle green triangle, Ring orange diamond, Pinky purple heart) + number | ⬜ |
| KID-2 | Preschool-sized buttons (≥ 96 pt), no notation/jargon | ⬜ |
| KID-3 | Animated cartoon avatar reacting to performance; mirrors child's smile from front-camera face landmarks | ⬜ |
| KID-4 | Confetti/stars on success | ⬜ |
| KID-5 | Gentle feedback only: soft lavender pulse + glowing hint key, no red, no error sound | ✅ (engine) / ⬜ (visuals) |
| KID-6 | Falling-notes lane + highlighted key grid, green success flash | ⬜ |
| KID-7 | Step-by-step calibration with big hand-print outlines + spoken instructions | ✅ (logic) / ⬜ (UI) |
| KID-8 | Grown-ups corner behind a press-and-hold gate | ⬜ |

## 5. Non-functional requirements
* iPad only, landscape, iPadOS 17+; M4 iPad Pro is the reference device.
* Hand tracking ≥ 30 fps, target 60 fps; UI stays at 60 fps (ProMotion).
* Privacy: camera frames processed in memory only; no network use except the optional lesson endpoint (text only).
* Accessibility: shapes + numbers (not colour alone), VoiceOver labels on all buttons, Reduce Motion respected for confetti.

## 6. Known limitations (be honest with testers)
* The iOS Simulator has **no camera and no MIDI hardware** — live tracking can only be verified on a real iPad. A *Demo hands* mode simulates tracking for UI checks.
* The "AI" cloud pipeline does not exist yet: `MockLessonTransport` only knows the built-in songs; everything else becomes a labelled *practice tune*.
* TrueDepth/ARKit face tracking conflicts with using the same front camera for video + hands, so smile mirroring uses Vision face landmarks instead (coarse).
* Fingertip-over-key attribution from a 2-D image is approximate (± ~1 white key); when uncertain the app is lenient and counts the note.

## 7. Acceptance checklist (for the on-device test round)
See `docs/TEST_PLAN.md` (created when the build is ready for you).
