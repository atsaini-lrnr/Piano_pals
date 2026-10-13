# Piano Pals — On-device test plan (iPad Pro M4)

What the Simulator **cannot** check (no camera, no MIDI hardware) is listed here. Everything else is already covered by
automated tests: `PianoPalsTests` (94 unit tests) and `PianoPalsUITests` (7 touch tests).

## 0. Install
1. Open `PianoPals.xcodeproj` in Xcode.
2. Select the **PianoPals** target → *Signing & Capabilities* → choose your Team and change the bundle ID from
   `com.example.PianoPals` to one you own.
3. Plug in the iPad, select it as the run destination, press ⌘R. Allow the camera prompt.
4. Optional: run the automated tests first (⌘U on an iPad simulator).

## 1. Camera + overlay (front/side camera)
| # | Do | Expect |
|---|---|---|
| 1.1 | Open Home | "Camera" chip turns ✓ |
| 1.2 | Start any song | "Side view" tile shows live video; no stretching |
| 1.3 | Hold a hand over the keys | Coloured numbered circles (1 red star-ish, 2 blue, 3 green, 4 orange, 5 purple) sit on your fingertips and follow them smoothly |
| 1.4 | Grown-ups ▸ Diagnostics | fps ≈ 30–60, hand count matches reality |
| 1.5 | Picture sideways or upside down? | Use Grown-ups ▸ Cameras ▸ *Turn picture* / *Flip* until upright |

## 2. iPhone as overhead camera ("camera mode")
iPadOS can't use an iPhone as a normal camera, so Piano Pals does it itself. Both devices run the **same app**; the iPhone automatically shows a camera screen.
Setup: install the app on the iPhone too (Xcode: choose the iPhone as run destination, same Team). Both on the same Wi-Fi.
| # | Do | Expect |
|---|---|---|
| 2.1 | Open Piano Pals on the iPhone; allow Camera and **Local Network** | Camera screen, "Waiting for the iPad…", an 8-digit **pairing code** |
| 2.2 | iPad: lesson screen ▸ *Use my iPhone* (or Grown-ups ▸ Choose cameras); allow **Local Network** | Your iPhone's name appears in "Looking for iPhones…" within a few seconds |
| 2.3 | Tap it, type the code | iPad: "Connected to …" with updates/s and ms; iPhone: "Connected to the iPad" |
| 2.4 | Prop the iPhone above the keys, pointing down; look at the iPad's **Top view** tile | Live picture + coloured numbered finger dots on your hand |
| 2.5 | Wrong picture orientation? | iPad: Grown-ups ▸ Cameras ▸ *Turn picture / Flip* (it tells the iPhone), or the buttons on the iPhone |
| 2.6 | Lock/unlock iPhone, walk out of range, come back | iPad reconnects by itself (code is remembered); no crash |
| 2.7 | Wrong code | "Couldn't connect… check the pairing code" and the prompt again |
**Report:** the "updates/s" and "ms" numbers, whether dots follow fingers smoothly, and whether the iPad's Diagnostics "Finger seen by camera" improves with the top view. If the iPhone isn't listed: Settings ▸ Privacy ▸ Local Network ▸ Piano Pals must be on for *both* devices.
Optional: a USB-C webcam plugged into the iPad appears in Choose cameras as an external camera.

## 3. MIDI keyboard (USB-C)
| # | Do | Expect |
|---|---|---|
| 3.1 | Plug keyboard into USB-C, power on | Home chip "Piano ✓"; Grown-ups ▸ Piano lists its name |
| 3.2 | Open a lesson, play keys | Pressed key darkens on screen; correct key flashes green + confetti; wrong key = soft lavender pulse, no red, no error sound |
| 3.3 | Unplug while holding a key | No stuck key, status flips to "No keyboard found" |
| 3.4 | Grown-ups ▸ Piano ▸ Keyboard size | Set to match your keyboard |

## 4. Hand calibration ("My Hands")
| # | Do | Expect |
|---|---|---|
| 4.1 | Tap *My Hands*, place right hand in C position (thumb on middle C) on the print | Outline turns yellow (hand seen) then green; ring fills in ~1.5 s; confetti; moves to left hand |
| 4.2 | Finish both | "All done!" + stars. Grown-ups ▸ Calibration shows ✓ |
| 4.3 | Play C-D-E-F-G with thumb→pinky | Notes count as perfect; using the wrong finger still advances but softly pulses the finger badge |
**Report:** how many tries before the hand "snaps" to the print, and whether small hands (child) work.

## 5. Child experience
* Buttons big enough for a 5-year-old? Panda reacts (cheer / encourage)? Smiling at the front camera makes the panda smile more?
* Spoken helper audible and friendly? (Grown-ups ▸ Spoken helper)
* "Grown-ups: hold" requires a deliberate ~1 s press?

## 6. Lesson generator (Grown-ups ▸ Add a song)
* "Ode to Joy by Beethoven" → added from the (mock) service.
* A YouTube link or an unknown title → added as a labelled *Practice tune made on this iPad* (the cloud AI doesn't exist yet).
* `C4 D4 E4 F4 G4 F4 E4 D4 C4:2` → fingered locally. Import a `.mid` file → fingered locally.

## 7. What to send back
Screenshots/videos of 1.3, 2.2, 4.1, plus anything that felt wrong, laggy or confusing.
