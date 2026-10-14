# Piano Pals — PRD v3: Coaching layout, Practice, Web search, On-device transcription

_Feedback round after hardware testing (iPad + iPhone camera mode working). Companion to `PRD.md` (v1) and `PRD_AI_COACH.md` (v2). Status is updated as work lands. Last updated: 2026-10-14._

## 1. What the tester asked for
1. **Layout:** camera on top, lesson underneath (not left/right). More piano keys visible. The camera area should *coach*: point at mistakes and show the correction.
2. **Practice, not just songs:** beginner exercises, scales for right and left hand, and a "practice block" (a short routine).
3. **Songscription-style generation on device:** turn audio into playable notes without a cloud service.
4. **Better search for grown-ups:** don't stop at the 18-song database — look on the web (legally), and convert what's found.

## 2. Principles (unchanged)
Child-safe (never negative), honest (never fake a song), private (audio/video stay on device; only search *words* leave, only on a grown-up's request, and only to free/legal sources), licence-clean (public-domain / open licences only, shown to the grown-up).

## 3. Features and success metrics
Legend: ✅ met & automatically verified · 🟡 built, needs device/real-world check · ⬜ not started

### F12 Coaching layout (top camera / bottom lesson)
| ID | Metric | Target | How measured | Status |
|---|---|---|---|---|
| L1 | Camera section is above the lesson and ≥ 35 % of the height | pass | UI test on element frames | ⬜ |
| L2 | Keyboard spans ≥ 90 % of the width and shows ≥ 15 white keys | pass | UI test + unit test of span | ⬜ |
| L3 | A wrong finger is shown on the camera within 100 ms: ring on the right finger + arrow from the finger used | pass | Unit test of `CorrectionPresenter`; visual check | ⬜ |
| L4 | The target key is marked on the live picture (when the keyboard is calibrated) | pass | Unit test of marker geometry | ⬜ |
| L5 | Correction never uses red or negative words | 0 | Test | ⬜ |
### F13 Practice
| ID | Metric | Target | How measured | Status |
|---|---|---|---|---|
| E1 | Exercises available | ≥ 40, every category non-empty | Unit test | ⬜ |
| E2 | Scales use the standard fingerings (C G D A E: RH 1-2-3-1-2-3-4-5, LH 5-4-3-2-1-3-2-1; F: RH 1-2-3-4-1-2-3-4) and correct notes, up and down | 100 % | Unit test over every scale and hand | ⬜ |
| E3 | Right-hand exercises sit above middle C, left-hand below it; fingers always 1–5 | 100 % | Unit test | ⬜ |
| E4 | Daily practice block: ≤ 12 minutes, includes both hands, a scale, and a drill for the child's weakest finger when one is known | pass | Unit test | ⬜ |
| E5 | A block runs start-to-finish with a "Next" step and a done screen | pass | UI test | ⬜ |
### F14 Web search for grown-ups
| ID | Metric | Target | How measured | Status |
|---|---|---|---|---|
| W1 | Only openly-licensed files are ever offered (public domain, CC0, CC BY, CC BY-SA); NC / ND / unknown are dropped | 0 leaks | Unit test | ⬜ |
| W2 | Mutopia and Wikimedia Commons responses parse into candidates with licence, composer, size | pass | Unit tests on captured responses | ⬜ |
| W3 | Downloads are capped (≤ 600 KB) and must be real MIDI files | pass | Unit test | ⬜ |
| W4 | A multi-track classical MIDI becomes a playable, fingered excerpt (≤ 64 notes, in the hand's range) | pass | Unit test on synthetic MIDI | ⬜ |
| W5 | Live: ≥ 7 of 10 well-known public-domain pieces return a usable candidate | ≥ 70 % | Live check from the app | ⬜ |
| W6 | Search is explicit and explained: the screen says which sites get the search words | pass | UI test | ⬜ |
### F15 On-device audio → notes
| ID | Metric | Target | How measured | Status |
|---|---|---|---|---|
| T1 | Import an audio file (wav/m4a/mp3…), resample to 22.05 kHz mono on device | pass | Unit test | ⬜ |
| T2 | Basic Pitch window stitching and note decoding are exact on synthetic activations | F1 = 1.0 | Unit test | ⬜ |
| T3 | Polyphonic → right-hand melody + left-hand bass lessons | pass | Unit test | ⬜ |
| T4 | Works without the AI model for single-voice audio (YIN fallback) | pass | Unit test on synthetic audio | ⬜ |
| T5 | With the Core ML model installed: note F1 on a real piano clip | ≥ 0.8 | **needs the model (see §5)** and a clip | ⬜ |
| T6 | 30 s clip transcribed in < 15 s on the iPad | pass | Device timing | ⬜ |

## 4. Out of scope / honest limits
* Audio ripped from YouTube/streaming is not supported (terms of service, copyright). Audio the user owns/imports is.
* Free sources contain public-domain *classical and folk* music, not current pop.
* Two-handed lessons (both hands at once) are the next step after single-hand practice.

## 5. Resources needed from the owner
* Permission to download the Basic Pitch Core ML model (Spotify, Apache-2.0; ≈ a few MB) — see the question in the chat.
* A short piano recording you own (≈ 20 s) to measure T5.
