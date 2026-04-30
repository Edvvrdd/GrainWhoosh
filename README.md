# GranularWhoosh

A granular sound design tool built directly into REAPER. Unlike traditional sealed instruments or rigid sample libraries, GranularWhoosh turns your entire session into the granular engine. It features a uniquely flexible workflow where every processing stage is fully editable on the timeline — you can tweak volume, pan, pitch, and filter envelopes post-generation, and even recursively re-granulate your output with a single click.



## Requirements

- REAPER 6.x or newer
- [ReaImGui](https://github.com/cfillion/reaimgui) (install via ReaPack)
- ReaPitch (ships with REAPER; make sure Cockos plugins are enabled in Preferences → Plug-ins → VST)

## Install via ReaPack

1. Install [ReaPack](https://reapack.com) if you haven't already
2. In REAPER: **Extensions → ReaPack → Manage repositories**
3. Click **Import/export → Import repositories**
4. Paste this URL: [https://raw.githubusercontent.com/Edvvrdd/GrainWhoosh/main/index.xml](https://raw.githubusercontent.com/Edvvrdd/GrainWhoosh/main/index.xml)
5. **Extensions → ReaPack → Synchronize packages**
6. Run `Script: GranularWhoosh.lua` from the Actions list

## Workflow

1. Create a folder track; add audio items to child tracks beneath it
2. Select the folder track in REAPER
3. Make a time selection spanning the desired whoosh length
4. Click **Generate Stereo** or **Generate Mono**
5. A temp track (default `GW_Temp`) appears at the top of the project with the glued whoosh plus editable volume, pan, pitch, and filter envelopes
6. Drag envelope points, add FX to the temp track, audition in place
7. Click **Resample to Folder** to move the result into the folder as a new child source, or click **Render** to bounce through the full signal chain to a new track

## Buttons

| Button | Action |
|---|---|
| **Generate Stereo** | Fresh whoosh with a new random seed, stereo output |
| **Generate Mono** | Same but mono; pan envelope is written flat |
| **Render** | Bounce the temp track through its full signal chain (including ReaPitch, ReaEQ, ReaComp) to a new track below it |
| **Resample to Folder** | Move the glued item from the temp track into the source folder as a new child track — enables recursive granulation without leaving the folder ecosystem |

## Controls

### Source / Sampling section

- **Sampling Mode** — `Uniform` (classic granular: grains cycle through all sources with random offsets) or `Sequential` (each source gets one grain in order, auto-sized to fill the time selection)
- **Grain Size** — duration of each slice in Uniform mode (10–500 ms); ignored in Sequential mode where grain size is auto-calculated
- **Grain Density** — how densely grains overlap; higher values = thicker texture (shown as overlap percentage)
- **Positional Randomness** — random offset in the source read-head per grain
- **Pitch/Direction Randomness** — random pitch variation per grain via playback rate
- **Sampling Direction** — how sources are ordered: Forward, Reverse, Ping-Pong, or Random
- **Inset** — shrinks the grain placement window inside the time selection, giving silent margins at each end

### Volume Envelope section

A live preview shows the exact bezier curve that will be written to the temp track's volume envelope.

- **Peak Position** — where in the whoosh the loudest moment sits (0 = start, 1 = end)
- **Hold Time** — fraction of the duration the peak is sustained (0–0.5); creates a flat plateau at maximum
- **Rise Tension** — curvature of the attack; positive bows upward (fast rush-in), negative concaves (slow building tension)
- **Fall Tension** — same for the release side
- **Front Spill** — extends the envelope start before the time selection (seconds)
- **Back Spill** — extends the envelope end after the time selection (seconds)
- **Compression** — adds ReaComp to the temp track; controls threshold and ratio together (0% = bypass, 100% = heavy)

### Doppler section

Toggles pitch, filter, and pan envelopes that simulate a moving sound source. All three share the same attack/release curvature from the Volume Envelope section but have independent peak positions.

**Pitch**
- **Intensity** — maximum pitch deviation at the peak (±semitones, 0–24)
- **Pitch Dir** — up-then-down (approach) or down-then-up (recede feel)
- **Pitch Offset** — shifts the pitch peak earlier or later relative to the volume peak (seconds)

**Filter**
- **Base Freq** — lowpass filter frequency at the edges of the whoosh (20–2000 Hz)
- **Peak Freq** — lowpass filter frequency at the peak (1000–20000 Hz)
- **Filter Offset** — shifts the filter peak relative to the volume peak (seconds)

**Pan**
- **Strength** — maximum pan offset at the edges of the whoosh (0 = center, 1 = full left/right)
- **Pan Dir** — L→R or R→L sweep
- **Pan Offset** — shifts the pan peak relative to the volume peak (seconds)

### Output / Generation section

- **Inset** — shrinks the grain placement window inside the time selection. allowing for longer sampling duration but generating a quicker sounding whoosh
- **Track Name** — name of the temp track; auto-appends `_1`, `_2`, etc. if a track with that name already exists
- **Status** — live feedback on generation progress and errors

## Preview Visualizer

The live preview at the bottom of the window shows:

- **Volume envelope** (cyan) — the bezier curve that will be written to the temp track
- **Pitch envelope** (magenta) — ReaPitch automation curve (visible when Doppler is enabled)
- **Filter envelope** (green) — ReaEQ lowpass automation curve (visible when Doppler is enabled)
- **Grain background** — in Uniform mode, a dense texture of vertical lines; in Sequential mode, numbered blocks with neon borders showing source order

## Recursive granulation

The output of one whoosh can become the source for the next. Use **Resample to Folder** to move the glued item into the source folder as a new child track, select the folder, make a new time selection, and hit Generate again. Stack as many layers as you like — a whoosh-of-whooshes-of-whooshes takes about 30 seconds.

## Known limitations

- Source files must still exist at their original paths; grains skip sources that have been moved or deleted since the last session
- ReaPack auto-update requires syncing manually; REAPER doesn't push updates automatically
- Sequential mode supports up to 10 source tracks

## Credits

Heavily inspired by [ReaWhoosh](https://reaper.blog/2026/02/reawhoosh-generator-reaper-script/) by SBP — studying that script's envelope-handling patterns was essential to getting GranularWhoosh's timeline integration working reliably.

Design sensibility informed by [Tonsturm Whoosh](https://tonsturm.com/product/whoosh).

Thanks to the REAPER scripting community and the maintainers of [ReaImGui](https://github.com/cfillion/reaimgui).

## License

MIT

## Feedback

Issues and feature requests welcome on the [GitHub issues page](https://github.com/Edvvrdd/GrainWhoosh/issues). Particularly interested in hearing about source-material combinations that produce unexpected results — the tool was designed for emergent texture and the failure modes are often more interesting than the successes.
