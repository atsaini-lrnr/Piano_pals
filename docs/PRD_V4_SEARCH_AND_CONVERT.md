# PRD v4 — "Find a song and turn it into a lesson" (F16 write-up, F17 plan)

Status: research done 2026-10-14. Nothing here is built yet except what is marked ✅. Sources are linked at the end.

## 1. What the online tools do (and what they cost)

| Kind | Examples | How it works | Cost / limits |
|---|---|---|---|
| Audio → notes/MIDI/sheet | Songscription, AI-MIDI style sites, musci.io | You upload audio; a cloud model finds pitch, timing, length of each note; a piano roll comes back | Songscription's own FAQ: about 15 min of audio a month free, paid above (third-party pages disagree, so check their pricing page). Other sites cap file size (musci.io 50 MB) or length. Output is a rough draft |
| Link → MIDI | "YouTube to MIDI" sites | Pull the audio out of the YouTube video, then do the above | Free sites come and go. **Pulling audio from YouTube breaks YouTube's Terms of Service** (no downloading except where YouTube offers it, no automated scraping). We will not do this |
| Full song (vocals, drums) → MIDI | songfinder.gg and others | Split the mix into stems (vocals, drums, bass, other), then transcribe each | Needs a stem-splitting model (large). Quality drops on dense pop mixes |

## 2. What we can do for free, on the iPad, legally

| Piece | Free? | Status |
|---|---|---|
| Audio file → notes, on the iPad, no upload, no limit (Basic Pitch, Apache-2.0) | Yes | ✅ F15 |
| Open-licence MIDI from Mutopia / Wikimedia Commons | Yes | ✅ F14 |
| Link → title only (YouTube oEmbed), then match | Yes | ✅ |
| Listen: play or hum near the iPad | Yes | ✅ |
| **"Is this the song?" list** from Apple's iTunes Search API: title, artist, album, year, artwork, 30 s preview to play. No key, no account; Apple documents about 20 calls a minute. Checked live today: "when we were young" returned Adele, The Killers, Passenger… with previews | Yes | ⬜ F17 |
| MusicBrainz (open music database): canonical title, artist, length to tell versions apart. No key; they ask for a descriptive User-Agent and about 1 request a second. Checked live today | Yes | ⬜ F17 |
| Spotify Web API | Account needed; unauthenticated search returned 401 today; since 27 Nov 2024 new apps lose 30 s previews and audio analysis; a client secret would have to live on a server | No (not worth it) |
| YouTube Data API search | Needs an API key; the default free quota is roughly 100 searches a day for the whole app (Google's docs and third-party guides disagree on the exact accounting) | Not at launch. Pasting a link already works |
| Apple Music via MusicKit | Needs a paid developer token and a subscription | No; iTunes Search covers it |
| Songscription as a service | 15 min/month free, cloud upload, account | No: breaks "everything stays on the iPad" |
| Stem splitting (e.g. Demucs, open source) for full songs | Free licence, but a big model and heavy compute | Later, optional. Needs a decision |

## 3. The honest limit

For a modern copyrighted song (for example Adele, "When We Were Young") there is **no free, legal MIDI file online**. Sites that offer one are mostly unlicensed, and we will not offer them. So the app can identify the song and then offer only real options:

1. It's in our free library or in an open-licence file → add it (✅ today).
2. You own a recording (a file, a voice memo, a clip) → "Make a lesson from a recording" (✅ F15).
3. Play or hum it near the iPad (✅ Listen).
4. A clearly-labelled practice tune.

The 30 s iTunes preview is for **identifying** the song (the grown-up plays it to confirm). We do not run note detection on it: Apple provides it for promotion, not analysis.
Music-library tracks bought as DRM-free files can be picked as files; Apple Music subscription downloads are protected and cannot be read.

## 4. F17 — a browser-like search for grown-ups (plan)

One search box, one sheet, steps with visible progress:

1. **Search** "when we were young". Steps tick off as they finish: *Your songs* → *Free library* → *Song catalogue (Apple, MusicBrainz)* → *Free open files (Mutopia, Commons)*.
2. **Results in sections**: "In your app" · "Is this the song?" (artwork, artist, year, ▶ 30 s preview, tap to choose) · "Free files we can use".
3. **Choose a song → "What we can do"** card with a checklist and a button for each real option from section 3, plus progress when it downloads, converts and fingers (the same steps F14 and F15 already use).
4. **Privacy line** before the first catalogue search: which sites get the words (Apple's iTunes Search and MusicBrainz), nothing else leaves the iPad. One-tap, explained, like F14.

Build order: (a) pure `SongSearchCoordinator` with a step/progress model and stubs, tests; (b) the two lookups (iTunes, MusicBrainz) with parsers and tests on captured responses; (c) sheet UI with step list and result sections; (d) "What we can do" panel wired to existing F14/F15/Listen/practice-tune actions; (e) UI test with stubs and a live check.

## 5. Needs the user's decision

1. OK to send the search words to Apple's iTunes Search and MusicBrainz (free, no account, explained on screen)?
2. Full-mix songs: leave for later, or add a stem-splitting model (large download)?

## Sources

- Songscription: https://www.songscription.ai/audio-to-midi and https://www.songscription.ai/audio-to-sheet-music
- musci.io, songfinder.gg (audio-to-MIDI pages found in the search)
- YouTube Terms of Service: https://www.youtube.com/terms
- YouTube Data API overview: https://developers.google.com/youtube/v3/getting-started
- Spotify Web API changes (27 Nov 2024): https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api
- iTunes Search API: https://performance-partners.apple.com/resources/documentation/itunes-store-web-service-search-api/
- MusicBrainz web service: https://musicbrainz.org/doc/MusicBrainz_API
