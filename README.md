# GrainWhoosh

A granular sound design tool built directly into REAPER. Your session is the sample library, every processing stage is editable on the timeline, and the output can be re-granulated as a new source with one click.

Built for sound designers who want whoosh-and-beyond without a sealed instrument or external sample library.

## Positioning

GrainWhoosh is a **granular texture generator**. It produces dense, motion-infused textures built from your own sources — wind beds, magical auras, transitional swells, layered impact tails, granular swarms.

For **narrative pass-by effects** with distinct approach/impact/recede character (sword swings, car fly-bys, cinematic whooshes), tools like [Tonsturm Whoosh](https://tonsturm.com/product/whoosh) are better suited — they have dedicated source-mixing engines designed for that storytelling shape.

Both tools can sit side-by-side in a sound designer's workflow. They do different jobs.

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
6. Run `Script: GrainWhoosh.lua` from the Actions list

## Workflow

1. Create a folder track; add audio items to child tracks beneath it
2. Select the folder track in REAPER
3. Make a time selection spanning the desired whoosh length
4. Click **Gen stereo** or **Gen mono**
5. A `GW_Temp` track appears above the folder with the glued whoosh plus editable volume, pan, and pitch envelopes
6. Drag envelope points, add FX to `GW_Temp`, audition in place
7. Click **Render** when you're happy to bounce the result to a new audio file on a new track

## Buttons

| Button | Action |
|---|---|
| **Gen stereo** | Fresh whoosh with a new random seed, stereo output |
| **Gen mono** | Same but mono; pan envelope is written flat |
| **Render** | Bounce `GW_Temp` through its full signal chain to a new track below it |
| **Regen stereo / mono** | Re-run with current UI values but the same grain positions as last generate — useful when tweaking envelope shape or pitch range without wanting new randomness |
| **Shuffle** | Re-roll grain positions with a new random seed, keeping current mono/stereo mode |

## Controls

### Grain section

- **Grain size** — duration of each slice (10–500 ms)
- **Density** — how densely grains overlap; higher values = thicker texture
- **Pitch rnd** — random pitch variation per grain (±semitones)
- **Pos rnd** — random offset in the source read-head per grain
- **Reverse rnd** — probability of a grain being reversed
- **Playback mode** — how the source read-head sweeps: forward, reverse, bidirectional, random

### Whoosh envelope section

A live preview shows the exact bezier curve that will be written to the temp track's volume envelope.

- **Peak position** — where in the whoosh the loudest moment sits (0 = start, 1 = end)
- **Rise tension** — curvature of the attack; positive bows upward (fast rush-in), negative concaves (slow building tension)
- **Fall tension** — same for the release side
- **Pitch range** — maximum pitch deviation at the peak (ReaPitch envelope)
- **Pitch direction** — up-then-down (approach) or down-then-up (recede feel)
- **Pan amount** — maximum pan offset at the edges of the whoosh
- **Pan direction** — L→R or R→L sweep

### Output section

- **Temp track name** — name of the track GrainWhoosh creates
- **Edge inset** — shrinks the grain placement window inside the time selection, giving silent margins at each end

## FX processing

GrainWhoosh reads **source files from disk** when generating grains, so FX on child tracks or take FX are **not** baked in automatically. Three supported patterns:

**Per-source FX** — add take FX or child-track FX, select the source item, run action `40209` ("Apply track/take FX to items as new take") before Generate. The baked take replaces the original on disk. Revert with action `40127` ("Take: Crop to previous take in items").

**Post-generate FX** — add FX directly to `GW_Temp` after Generate. These apply at render time automatically because Render pipes `GW_Temp`'s full signal chain through a bounce.

**Folder FX** — are **not** captured by GrainWhoosh because the tool reads child items directly, not the folder's summed output. Move folder FX to `GW_Temp` instead.

## Recursive granulation

The output of one whoosh can become the source for the next. Drag the glued item from `GW_Temp` onto a child track, select the folder, make a new time selection, and hit Generate again. Stack as many layers as you like — a whoosh-of-whooshes-of-whooshes takes about 30 seconds.

## Known limitations

- Source files must still exist at their original paths; grains skip sources that have been moved or deleted since the last session
- Only one folder can be the source at a time
- Glued item length may be slightly shorter than the time selection due to grain hop alignment at the tail
- ReaPack auto-update requires syncing manually; REAPER doesn't push updates automatically

## Credits

Heavily inspired by [ReaWhoosh](https://reaper.blog/2026/02/reawhoosh-generator-reaper-script/) by SBP — studying that script's envelope-handling patterns was essential to getting GrainWhoosh's timeline integration working reliably.

Design sensibility informed by [Tonsturm Whoosh](https://tonsturm.com/product/whoosh).

Built collaboratively with Claude (Anthropic) across [N] sessions of iteration. Architectural decisions, UX design, workflow direction, and scope choices are mine; much of the Lua implementation was drafted with AI assistance and refined through debugging.

Thanks to the REAPER scripting community and the maintainers of [ReaImGui](https://github.com/cfillion/reaimgui).

## License

MIT

## Feedback

Issues and feature requests welcome on the [GitHub issues page](https://github.com/YOUR_USERNAME/GrainWhoosh/issues). Particularly interested in hearing about source-material combinations that produce unexpected results — the tool was designed for emergent texture and the failure modes are often more interesting than the successes.
