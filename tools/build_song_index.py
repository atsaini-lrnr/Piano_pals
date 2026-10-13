#!/usr/bin/env python3
"""Build / extend Piano Pals' song index from a folder of MIDI files.

Usage:
  tools/build_song_index.py INPUT_DIR [--index PianoPals/Resources/SongIndex.json] [--max-notes 48] [--dry-run]
  tools/build_song_index.py --selftest

INPUT_DIR must contain `manifest.csv` with columns:
  file,title,composer,license,source,aliases,emoji        (aliases separated by ';')
Every row MUST carry a licence ("CC0", "Public domain ...", "CC BY ...", "CC BY-SA ..."). Rows without an acceptable
licence are rejected — this tool never adds unlicensed melodies.

For each .mid it extracts a single melody line (the highest note at each onset), trims it to the first N notes,
shifts it by whole octaves into a child-friendly register, rejects tunes spanning more than 19 semitones, and writes
note-name notation (C4 D4:2 ...) that the app parses at runtime.
No third-party packages are needed.
"""
import argparse, csv, json, os, re, struct, sys, tempfile

ALLOWED_LICENSE = re.compile(r"^(cc0|public domain|cc[- ]by|cc[- ]by[- ]sa|original)", re.I)
NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def read_vlq(data, i):
    value = 0
    for _ in range(4):
        b = data[i]; i += 1
        value = (value << 7) | (b & 0x7F)
        if not b & 0x80:
            return value, i
    raise ValueError("bad VLQ")


def parse_midi(data):
    """Return (notes, ticks_per_quarter, tempo_micros). notes = [(start_tick, end_tick, pitch)]."""
    if data[:4] != b"MThd":
        raise ValueError("not a MIDI file")
    _fmt, ntrks, division = struct.unpack(">HHH", data[8:14])
    if division & 0x8000:
        raise ValueError("SMPTE timing unsupported")
    i = 8 + struct.unpack(">I", data[4:8])[0]
    tempo = None
    notes = []
    for _ in range(ntrks):
        if data[i:i + 4] != b"MTrk":
            break
        length = struct.unpack(">I", data[i + 4:i + 8])[0]
        i += 8
        end = i + length
        tick = 0
        running = 0
        open_notes = {}
        while i < end:
            delta, i = read_vlq(data, i)
            tick += delta
            status = data[i]
            if status < 0x80:
                status = running
            else:
                i += 1
                if status < 0xF0:
                    running = status
            if status == 0xFF:
                kind = data[i]; i += 1
                n, i = read_vlq(data, i)
                if kind == 0x51 and n == 3 and tempo is None:
                    tempo = int.from_bytes(data[i:i + 3], "big")
                i += n
            elif status in (0xF0, 0xF7):
                n, i = read_vlq(data, i)
                i += n
            else:
                kind, channel = status & 0xF0, status & 0x0F
                size = 1 if kind in (0xC0, 0xD0) else 2
                d1 = data[i]; d2 = data[i + 1] if size == 2 else 0
                i += size
                if channel == 9:
                    continue
                if kind == 0x90 and d2 > 0:
                    open_notes.setdefault((channel, d1), []).append(tick)
                elif kind == 0x80 or (kind == 0x90 and d2 == 0):
                    starts = open_notes.get((channel, d1))
                    if starts:
                        notes.append((starts.pop(0), tick, d1))
        i = end
    return notes, division, tempo or 500000


def melody(notes):
    """Highest note per onset, then trim overlaps so the line is monophonic."""
    best = {}
    for start, end, pitch in notes:
        if start not in best or pitch > best[start][1]:
            best[start] = (end, pitch)
    line = sorted((s, e, p) for s, (e, p) in best.items())
    mono = []
    for idx, (s, e, p) in enumerate(line):
        if idx + 1 < len(line):
            e = min(e, line[idx + 1][0])
        if e > s:
            mono.append((s, e, p))
    return mono


def to_notation(line, division, tempo_micros, max_notes):
    line = line[:max_notes]
    if len(line) < 8:
        raise ValueError("fewer than 8 notes")
    pitches = [p for _, _, p in line]
    if max(pitches) - min(pitches) > 19:
        raise ValueError("range wider than 19 semitones")
    median = sorted(pitches)[len(pitches) // 2]
    shift = 0
    while median + shift > 69:
        shift -= 12
    while median + shift < 57:
        shift += 12
    bpm = round(60_000_000 / tempo_micros)
    tokens = []
    cursor = line[0][0]
    for s, e, p in line:
        gap = (s - cursor) / division
        if gap >= 0.25:
            tokens.append("R:%g" % (round(gap * 4) / 4))
        beats = max(round((e - s) / division * 4) / 4, 0.25)
        pitch = p + shift
        name = "%s%d" % (NAMES[pitch % 12], pitch // 12 - 1)
        tokens.append(name if beats == 1 else "%s:%g" % (name, beats))
        cursor = e
    return " ".join(tokens), bpm


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def build(input_dir, max_notes):
    manifest = os.path.join(input_dir, "manifest.csv")
    out, rejected = [], []
    with open(manifest, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            title = (row.get("title") or "").strip()
            licence = (row.get("license") or "").strip()
            if not licence or not ALLOWED_LICENSE.match(licence):
                rejected.append((title or row.get("file"), "missing/unacceptable licence: %r" % licence))
                continue
            try:
                with open(os.path.join(input_dir, row["file"]), "rb") as f:
                    notes, division, tempo = parse_midi(f.read())
                notation, bpm = to_notation(melody(notes), division, tempo, max_notes)
            except Exception as error:  # noqa: BLE001 - report and continue
                rejected.append((title, str(error)))
                continue
            out.append({
                "id": slug(title), "title": title, "composer": (row.get("composer") or "Unknown").strip(),
                "emoji": (row.get("emoji") or "🎵").strip(), "tempoBPM": bpm, "notation": notation,
                "aliases": [a.strip().lower() for a in (row.get("aliases") or "").split(";") if a.strip()],
                "license": licence, "source": (row.get("source") or "").strip() or "unspecified",
            })
    return out, rejected


def selftest():
    def vlq(n):
        parts = [n & 0x7F]
        n >>= 7
        while n:
            parts.append((n & 0x7F) | 0x80)
            n >>= 7
        return bytes(reversed(parts))

    track = b"\x00\xff\x51\x03\x07\xa1\x20"  # 500000 µs = 120 bpm
    for pitch in [60, 62, 64, 65, 67, 65, 64, 62, 60]:
        track += vlq(0) + bytes([0x90, pitch, 90]) + vlq(480) + bytes([0x80, pitch, 0])
    track += b"\x00\xff\x2f\x00"
    midi = b"MThd" + struct.pack(">IHHH", 6, 0, 1, 480) + b"MTrk" + struct.pack(">I", len(track)) + track
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "walk.mid"), "wb").write(midi)
        open(os.path.join(d, "bad.mid"), "wb").write(midi)
        with open(os.path.join(d, "manifest.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["file", "title", "composer", "license", "source", "aliases", "emoji"])
            w.writerow(["walk.mid", "Test Walk", "Anon", "CC0", "selftest", "test walk;walk", "🐛"])
            w.writerow(["bad.mid", "Unlicensed", "Anon", "", "selftest", "", "🎵"])
        out, rejected = build(d, 48)
    assert len(out) == 1 and out[0]["id"] == "test-walk", out
    assert out[0]["notation"] == "C4 D4 E4 F4 G4 F4 E4 D4 C4", out[0]["notation"]
    assert out[0]["tempoBPM"] == 120
    assert len(rejected) == 1 and "licence" in rejected[0][1]
    print("selftest ok")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("input_dir", nargs="?")
    parser.add_argument("--index", default="PianoPals/Resources/SongIndex.json")
    parser.add_argument("--max-notes", type=int, default=48)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    if not args.input_dir:
        parser.error("INPUT_DIR required")
    new, rejected = build(args.input_dir, args.max_notes)
    existing = json.load(open(args.index, encoding="utf-8")) if os.path.exists(args.index) else []
    merged = {s["id"]: s for s in existing}
    for song in new:
        merged.setdefault(song["id"], song)  # never overwrite curated entries
    print("added %d, rejected %d" % (len([s for s in new if s["id"] not in {e["id"] for e in existing}]), len(rejected)))
    for title, why in rejected:
        print("  rejected %s: %s" % (title, why))
    if not args.dry_run:
        json.dump(list(merged.values()), open(args.index, "w", encoding="utf-8"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    sys.exit(main())
