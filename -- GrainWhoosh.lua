-- @description GrainWhoosh - Granular Whoosh Generator
-- @author Ed
-- @version 0.9.0-beta
-- @about
--   A granular sound design tool built directly into REAPER.
--   Your session is the sample library — drop audio items onto child
--   tracks of a folder, make a time selection, and click Generate.
--   The tool resamples the sources into a granulated whoosh with
--   editable volume, pan, and pitch envelopes ready to tweak.
--
--   Requires:
--     * REAPER 6.x or newer
--     * ReaImGui (install via ReaPack)
--     * ReaPitch (ships with REAPER)
--
--   Inspired by ReaWhoosh (SBP) and Tonsturm Whoosh. Built
--   collaboratively with Claude.
-- @changelog
--   v0.9.0-beta - Initial beta release

local r = reaper

-- ── Dependency check ────────────────────────────────────────────
if not r.ImGui_CreateContext then
  r.ShowMessageBox(
    "ReaImGui is required but not installed.\n\n" ..
    "Install it via ReaPack:\n" ..
    "Extensions > ReaPack > Browse packages\n\n" ..
    "Search for 'ReaImGui' and install.",
    "GrainWhoosh — missing dependency", 0)
  return
end

-- Optional: verify ReaPitch is available. Not fatal — user can replace
-- with another pitch plugin by editing PITCH_FX_NAME below.
local function pitch_fx_available()
  -- Attempt a dry add-by-name with instantiate=false sentinel.
  -- If the FX doesn't exist on the system, AddByName returns -1.
  local tmp_track_count = r.CountTracks(0)
  r.InsertTrackAtIndex(tmp_track_count, false)
  local tmp = r.GetTrack(0, tmp_track_count)
  local idx = r.TrackFX_AddByName(tmp, "VST: ReaPitch (Cockos)", false, -1)
  r.DeleteTrack(tmp)
  return idx >= 0
end

if not pitch_fx_available() then
  r.ShowMessageBox(
    "ReaPitch not found.\n\n" ..
    "GrainWhoosh uses ReaPitch (ships with REAPER) for the pitch " ..
    "envelope. Make sure Cockos plugins are enabled in:\n" ..
    "Options > Preferences > Plug-ins > VST",
    "GrainWhoosh — missing dependency", 0)
  return
end

-- ── ImGui context ───────────────────────────────────────────────
local ctx  = r.ImGui_CreateContext('GrainWhoosh')
local sans = r.ImGui_CreateFont('sans-serif', 12)
r.ImGui_Attach(ctx, sans)

-- ── State ───────────────────────────────────────────────────────
local state = {
  -- Source
  folder_track    = nil,
  folder_name     = "— none selected —",
  child_count     = 0,
  sel_start       = 0,
  sel_end         = 0,
  has_selection   = false,
  rand_seed    = 0,

  -- Generated range
  generated_start = 0,
  generated_end   = 0,
  has_glued_item  = false,

  -- Grain
  grain_size      = 80.0,
  density         = 0.6,
  pitch_rnd       = 2.0,
  pos_rnd         = 0.15,
  reverse_rnd     = 0.10,
  playback_mode   = 0,

  -- Envelope
  peak_pos        = 0.5,
  attack          = 0.5,   
  release         = 0.5,   
  pitch_range     = 6.0,
  pitch_direction = 0,        -- 0 = up/down (approach), 1 = down/up
  pan_amount      = 1.0,
  pan_direction = 0,
  
  -- Output
  time_offset     = 0.0,      -- 0..0.45 — inset grains by this fraction each side
  temp_track_name = "GW_Temp",
  is_mono         = false, 

  -- UI
  status_msg      = "Ready — select a folder track and time range",
  can_render      = false,
  is_generating   = false,
}

local EXT_SECTION = "GrainWhoosh_v1"

function save_settings()
  local keys = {
    "grain_size", "density", "pitch_rnd", "pos_rnd", "reverse_rnd",
    "playback_mode", "peak_pos", "attack", "release", "pitch_range",
    "pitch_direction", "pan_amount", "pan_direction", "time_offset",
    "temp_track_name",
  }
  for _, k in ipairs(keys) do
    local v = state[k]
    if type(v) == 'boolean' then v = v and '1' or '0' end
    r.SetExtState(EXT_SECTION, k, tostring(v), true)
  end
end

function load_settings()
  local keys = {
    grain_size      = 'number', density         = 'number',
    pitch_rnd       = 'number', pos_rnd         = 'number',
    reverse_rnd     = 'number', playback_mode   = 'number',
    peak_pos        = 'number', attack          = 'number',
    release         = 'number', pitch_range     = 'number',
    pitch_direction = 'number', pan_amount      = 'number',
    pan_direction   = 'number', time_offset     = 'number',
    temp_track_name = 'string',
  }
  for k, typ in pairs(keys) do
    if r.HasExtState(EXT_SECTION, k) then
      local raw = r.GetExtState(EXT_SECTION, k)
      if typ == 'number' then
        local n = tonumber(raw)
        if n then state[k] = n end
      else
        state[k] = raw
      end
    end
  end
end

load_settings()
r.atexit(save_settings)

local PLAYBACK_MODES = { "Forward sweep", "Reverse sweep", "Bidirectional", "Random" }
local PITCH_DIRS   = { "Up → down (approach)", "Down → up" }
local PAN_DIRS = { "Left → right", "Right → left" }

-- ── Helpers ─────────────────────────────────────────────────────
function section(label, body_fn)
  r.ImGui_SeparatorText(ctx, label)
  r.ImGui_Spacing(ctx)
  body_fn()
  r.ImGui_Spacing(ctx)
end

function labeled_slider(label, val, lo, hi, fmt)
  r.ImGui_SetNextItemWidth(ctx, -80)
  local changed, new_val = r.ImGui_SliderDouble(ctx, '##'..label, val, lo, hi, fmt)
  r.ImGui_SameLine(ctx)
  r.ImGui_TextDisabled(ctx, label)
  return changed and new_val or val
end

function labeled_combo(label, idx, items)
  r.ImGui_SetNextItemWidth(ctx, -80)
  local changed, new_idx = r.ImGui_Combo(ctx, '##'..label, idx, table.concat(items, '\0')..'\0')
  r.ImGui_SameLine(ctx)
  r.ImGui_TextDisabled(ctx, label)
  return changed and new_idx or idx
end

-- ── Refresh source info ─────────────────────────────────────────
function refresh_source_info()
  -- Guard against empty project
  if r.CountTracks(0) == 0 then
    state.folder_track  = nil
    state.folder_name   = "— no tracks in project —"
    state.child_count   = 0
    local ts, te = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
    state.sel_start     = ts
    state.sel_end       = te
    state.has_selection = (te > ts)
    return
  end

  local sel_tr = r.GetSelectedTrack(0, 0)
  if sel_tr and r.GetMediaTrackInfo_Value(sel_tr, 'I_FOLDERDEPTH') >= 1 then
    state.folder_track = sel_tr
    local _, name = r.GetSetMediaTrackInfo_String(sel_tr, 'P_NAME', '', false)
    state.folder_name = name ~= '' and name or '(unnamed)'

    local count = 0
    local ti = r.GetMediaTrackInfo_Value(sel_tr, 'IP_TRACKNUMBER')
    for i = ti, r.CountTracks(0) - 1 do
      local tr    = r.GetTrack(0, i)
      local depth = r.GetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH')
      if tr ~= sel_tr then
        if depth >= 0 then count = count + 1 end
        if depth < 0  then break end
      end
    end
    state.child_count = count
  else
    state.folder_track = nil
    state.folder_name  = "— none selected —"
    state.child_count  = 0
  end

  local ts, te = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  state.sel_start   = ts
  state.sel_end     = te
  state.has_selection = (te > ts)
end

-- ── Envelope preview ────────────────────────────────────────────
function draw_envelope_preview()
  local dl     = r.ImGui_GetWindowDrawList(ctx)
  local cx, cy = r.ImGui_GetCursorScreenPos(ctx)
  local W      = r.ImGui_GetContentRegionAvail(ctx)
  local H      = 64

  r.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + W, cy + H, 0x22222222, 3)
  -- Peak position guide line
  local peak_x = cx + W * state.peak_pos
  r.ImGui_DrawList_AddLine(dl, peak_x, cy, peak_x, cy + H, 0x22FFFFFF, 1)

  local att = math.max(-1.0, math.min(1.0, state.attack))
  local rel = math.max(-1.0, math.min(1.0, state.release))

  -- Helper: REAPER's bezier point tension curve between two envelope points.
  -- Matches the visual shape of shape=5 (bezier) envelope points in Reaper.
  -- t in [0,1] along the segment; tension_a at start, tension_b at end.
  -- Positive tension bows the curve toward higher values.
  local function bez(t, v0, v1, tension_a, tension_b)
    -- Cubic Bezier with control points derived from tension.
    -- Control points sit between the two end points, vertically offset
    -- by a factor of the tension, creating convex/concave arcs.
    local c0 = v0 + (v1 - v0) * (0.33 + tension_a * 0.33)
    local c1 = v1 - (v1 - v0) * (0.33 - tension_b * 0.33)
    local u  = 1 - t
    return u*u*u * v0
         + 3 * u*u*t * c0
         + 3 * u*t*t * c1
         + t*t*t * v1
  end

  local pts = {}
  local pk  = state.peak_pos
  for i = 0, 60 do
    local t = i / 60
    local v
    if t <= pk then
      -- Rise segment: 0 → 1, with attack as start tension
      local local_t = (pk > 0) and (t / pk) or 0
      v = bez(local_t, 0, 1, att, -rel)
    else
      -- Fall segment: 1 → 0, with -release as start tension
      local local_t = (pk < 1) and ((t - pk) / (1 - pk)) or 0
      v = bez(local_t, 1, 0, -rel, 0)
    end
    v = math.max(0, math.min(1, v))
    pts[#pts+1] = cx + t * W
    pts[#pts+1] = cy + H - v * (H - 6) - 3
  end

  local arr = r.new_array(pts)
  r.ImGui_DrawList_AddPolyline(dl, arr, 0xFF9F5AD4, 0, 1.5)

  -- Draw the three control points so the user sees what the envelope
  -- actually places when generated.
  local function dot(x, y, col)
    r.ImGui_DrawList_AddCircleFilled(dl, x, y, 3, col)
  end
  dot(cx,          cy + H - 3,                   0xFFAAAAAA)
  dot(cx + W * pk, cy + 3,                       0xFFFFFFFF)
  dot(cx + W,      cy + H - 3,                   0xFFAAAAAA)

  r.ImGui_Dummy(ctx, W, H)
end

-- ── Validate ────────────────────────────────────────────────────
function validate()
  if not state.folder_track then
    state.status_msg = "Select a folder track first"
    state.can_render = false
    return false
  end
  if state.child_count == 0 then
    state.status_msg = "Folder track has no children with media"
    state.can_render = false
    return false
  end
  if not state.has_selection then
    state.status_msg = "Set a time selection to define whoosh length"
    state.can_render = false
    return false
  end
  local dur = state.sel_end - state.sel_start
  state.status_msg = string.format(
    "Ready — %.2f s  |  %d source track%s  |  %.0f ms grains",
    dur, state.child_count, state.child_count ~= 1 and "s" or "", state.grain_size)
  state.can_render = true
  return true
end

-- ── Get or add gain FX on temp track ───────────────────────────
local PITCH_FX_NAME = "VST: ReaPitch (Cockos)"

function get_or_add_pitch_fx(track)
  local cnt = r.TrackFX_GetCount(track)
  for i = 0, cnt - 1 do
    local _, nm = r.TrackFX_GetFXName(track, i)
    if nm:find('ReaPitch', 1, true) then
      return i
    end
  end
  return r.TrackFX_AddByName(track, PITCH_FX_NAME, false, -1)
end

-- ── Apply whoosh envelope ───────────────────────────────────────
-- Uses GetFXEnvelope(true) — same pattern as ReaWhoosh.
-- This creates and arms the envelope atomically, no chunk needed.
function apply_whoosh_envelope()
  if not state.has_glued_item then return end

  local sel_start = state.generated_start
  local sel_end   = state.generated_end
  local peak_time = sel_start + (state.peak_pos * (sel_end - sel_start))

  local temp_track = nil
  for i = 0, r.CountTracks(0) - 1 do
    local tr      = r.GetTrack(0, i)
    local _, name = r.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
    if name == state.temp_track_name then
      temp_track = tr
      break
    end
  end
  if not temp_track then return end

  r.SetMediaTrackInfo_Value(temp_track, 'I_AUTOMODE', 1)

  local att = math.max(-1.0, math.min(1.0, state.attack))
  local rel = math.max(-1.0, math.min(1.0, state.release))

  -- Helper: write 3-point envelope given a handle and the three values
  local function write_3pt(env, v_start, v_peak, v_end)
    if not env then return end
    local n = r.CountEnvelopePoints(env)
    for i = n - 1, 0, -1 do
      r.DeleteEnvelopePointEx(env, -1, i)
    end
    r.InsertEnvelopePoint(env, sel_start, v_start, 5,  att, false, false)
    r.InsertEnvelopePoint(env, peak_time, v_peak,  5, -rel, false, false)
    r.InsertEnvelopePoint(env, sel_end,   v_end,   5,  0.0, false, false)
    local cnt = r.CountEnvelopePoints(env)
    r.SetEnvelopePoint(env, cnt-3, sel_start, v_start, 5,  att, false, true)
    r.SetEnvelopePoint(env, cnt-2, peak_time, v_peak,  5, -rel, false, true)
    r.SetEnvelopePoint(env, cnt-1, sel_end,   v_end,   5,  0.0, false, true)
    r.Envelope_SortPoints(env)
  end

  -- ── VOLUME envelope ───────────────────────────────────────────
    local vol_env = r.GetTrackEnvelopeByName(temp_track, 'Volume')
    if not vol_env then
      r.SetOnlyTrackSelected(temp_track)
      r.Main_OnCommand(40406, 0)
      vol_env = r.GetTrackEnvelopeByName(temp_track, 'Volume')
    end
    write_3pt(vol_env, 0.0, 716.0, 0.0)
  
    -- ── PAN envelope ──────────────────────────────────────────────
      -- Always write 3 points so the lane is ready to tweak.
      -- Mono: flat at 0 (centre). Stereo: −pan_amount → 0 → +pan_amount.
      local pan_env = r.GetTrackEnvelopeByName(temp_track, 'Pan')
      if not pan_env then
        r.SetOnlyTrackSelected(temp_track)
        r.Main_OnCommand(40407, 0)
        pan_env = r.GetTrackEnvelopeByName(temp_track, 'Pan')
      end
      if state.is_mono then
          write_3pt(pan_env, 0.0, 0.0, 0.0)
        else
          local pan_amt = state.pan_amount
          -- Flip sign based on direction
          local sign = (state.pan_direction == 0) and 1 or -1
          write_3pt(pan_env, -pan_amt * sign, 0.0, pan_amt * sign)
        end
  
    -- ── PITCH envelope ────────────────────────────────────────────
    local fx_idx = get_or_add_pitch_fx(temp_track)
    if fx_idx >= 0 then
      local pitch_env = r.GetFXEnvelope(temp_track, fx_idx, 0, true)
      if pitch_env then
        local st     = math.max(0.0, math.min(24.0, state.pitch_range))
        local centre = 24 / 48        -- 0.5 = no shift
        -- direction 0 = up at peak, 1 = down at peak
        local signed = (state.pitch_direction == 0) and st or -st
        local peak_n = (signed + 24) / 48
        write_3pt(pitch_env, centre, peak_n, centre)
      end
    end

  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()

  state.status_msg = string.format(
      "Done — %s  |  pitch %s%.1f st  |  inset %.0f%%",
      state.is_mono and "mono" or "stereo",
      state.pitch_direction == 0 and "+" or "-",
      state.pitch_range,
      state.time_offset * 100)
end

-- ── Generate ────────────────────────────────────────────────────
function do_generate(reshuffle)
  if not validate() then return end
  
  if reshuffle or state.rand_seed == 0 then
      state.rand_seed = math.floor(os.clock() * 1000000) % 2147483647
    end
    math.randomseed(state.rand_seed)

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  state.status_msg    = "Generating..."
  state.is_generating = true

  local sel_start = state.sel_start
  local sel_end   = state.sel_end
  local duration  = sel_end - sel_start

  -- 1. Walk child tracks
  local folder_idx = math.floor(
    r.GetMediaTrackInfo_Value(state.folder_track, 'IP_TRACKNUMBER')) - 1

  local child_tracks = {}
  local cum_depth    = 0
  for i = folder_idx + 1, r.CountTracks(0) - 1 do
    local tr    = r.GetTrack(0, i)
    local depth = r.GetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH')
    cum_depth   = cum_depth + depth
    if cum_depth < 0 then break end
    table.insert(child_tracks, tr)
  end

  -- 2. Build source pool
  local source_pool = {}
  for _, tr in ipairs(child_tracks) do
    for i = 0, r.CountTrackMediaItems(tr) - 1 do
      local item = r.GetTrackMediaItem(tr, i)
      local take = r.GetActiveTake(item)
      if take and not r.TakeIsMIDI(take) then
        local src      = r.GetMediaItemTake_Source(take)
        local src_file = r.GetMediaSourceFileName(src, '')
        local src_len  = r.GetMediaSourceLength(src)
        if src_file ~= '' and src_len > 0 then
          table.insert(source_pool, {
            file       = src_file,
            src_len    = src_len,
            start_offs = r.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS'),
          })
        end
      end
    end
  end

  if #source_pool == 0 then
    r.ShowMessageBox("No audio items found on child tracks!", "GrainWhoosh", 0)
    state.is_generating = false
    r.PreventUIRefresh(-1)
    r.Undo_EndBlock(string.format(
        "GrainWhoosh: Generate %s (%d grains, %.2fs)",
        state.is_mono and "mono" or "stereo",
        count,
        state.generated_end - state.generated_start), -1)
    return
  end

  -- 3. Find or create temp track, placed directly above the folder
    local temp_track = nil
    for i = 0, r.CountTracks(0) - 1 do
      local tr      = r.GetTrack(0, i)
      local _, name = r.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
      if name == state.temp_track_name then
        temp_track = tr
        break
      end
    end
  
    -- Always delete and recreate for a predictable slot, since user may
    -- have reorganised tracks between generates
    if temp_track then
      r.DeleteTrack(temp_track)
      temp_track = nil
    end
  
    -- Insert at the folder's current index, pushing folder down by one
    local folder_slot = math.floor(
      r.GetMediaTrackInfo_Value(state.folder_track, 'IP_TRACKNUMBER')) - 1
    r.InsertTrackAtIndex(folder_slot, true)
    temp_track = r.GetTrack(0, folder_slot)
    r.GetSetMediaTrackInfo_String(temp_track, 'P_NAME', state.temp_track_name, true)
  
    -- Set channel count per requested mode
    r.SetMediaTrackInfo_Value(temp_track, 'I_NCHAN', state.is_mono and 1 or 2)
    r.SetMediaTrackInfo_Value(temp_track, 'I_AUTOMODE', 1)

  -- 4. Force auto-crossfade on
  local xfade_was_on = r.GetToggleCommandState(40041) == 1
  if not xfade_was_on then r.Main_OnCommand(40041, 0) end


  -- Time offset inset (unchanged from before — must stay)
    local inset      = math.max(0.0, math.min(0.45, state.time_offset))
    local inset_s    = duration * inset
    local win_start  = sel_start + inset_s
    local win_end    = sel_end   - inset_s
    local win_dur    = math.max(0.001, win_end - win_start)
  -- 5. Grain generation — now with Doppler-style per-grain modulation
    local grain_s_base = state.grain_size / 1000.0
    local mode         = state.playback_mode
  
    -- Per-whoosh Doppler character
    -- Semitones at the peak — grains at centre are pitched up by this much,
    -- tail grains are pitched down. Independent of the post-glue pitch env.
    local doppler_st   = state.pitch_range * 0.7
    -- Density curve — grains cluster toward the peak
    local density_peak = state.density * 1.4
    local density_tail = state.density * 0.35
  
    local grain_items = {}
    local t, count    = win_start, 0
    local peak_t      = win_start + win_dur * state.peak_pos
  
    while t < win_end and count < 2000 do
      local s        = source_pool[math.random(1, #source_pool)]
      local progress = (t - win_start) / win_dur
      local max_offs = math.max(0.0, s.src_len - grain_s_base)
  
      -- Distance from peak, 0 at peak, 1 at edges
      local dist_from_peak = math.abs(progress - state.peak_pos) /
                             math.max(state.peak_pos, 1 - state.peak_pos)
      dist_from_peak = math.min(1.0, dist_from_peak)
  
      -- Doppler pitch: signed by direction, scaled by distance from peak.
      -- Approach side (before peak): pitch up. Recede side: pitch down.
      local side     = (t < peak_t) and 1 or -1
      if state.pitch_direction == 1 then side = -side end
      local dop_st   = side * doppler_st * (1 - dist_from_peak)
      local dop_rate = 2.0 ^ (dop_st / 12.0)
  
      -- Random pitch on top of Doppler
      local rnd_st    = (math.random() - 0.5) * 2.0 * state.pitch_rnd
      local rnd_rate  = 2.0 ^ (rnd_st / 12.0)
  
      -- Combined playrate — this is what gives each grain its velocity
      local rate = dop_rate * rnd_rate
  
      -- Grain size also scales with Doppler — peak grains are shorter
      -- (faster, tighter) while tail grains stretch out
      local size_scale = 0.6 + 0.4 * dist_from_peak
      local grain_s    = grain_s_base * size_scale
  
      -- Density scales from tail to peak — closer to peak = shorter hop
      local local_density = density_tail +
                            (density_peak - density_tail) * (1 - dist_from_peak)
      local hop_s         = grain_s * (1.0 - math.min(0.95, local_density * 0.75))
      hop_s               = math.max(hop_s, 0.001)
      local overlap_s     = math.max(0.0, grain_s - hop_s)
      local fade_len      = overlap_s * 0.5
  
      -- Base read-head position from playback mode
      local base_pos
      if mode == 0 then
        base_pos = s.start_offs + progress * max_offs
      elseif mode == 1 then
        base_pos = s.start_offs + (1.0 - progress) * max_offs
      elseif mode == 2 then
        local ph = (progress * 2.0) % 2.0
        base_pos = s.start_offs + (ph < 1.0 and ph or 2.0 - ph) * max_offs
      else
        base_pos = s.start_offs + math.random() * max_offs
      end
  
      local rnd_range = state.pos_rnd * max_offs
      base_pos = base_pos + (math.random() - 0.5) * 2.0 * rnd_range
      base_pos = math.max(0.0, math.min(s.src_len - grain_s, base_pos))
  
      local reversed = (state.reverse_rnd > 0) and (math.random() < state.reverse_rnd)
  
      local item_len = grain_s / math.abs(rate)
      local item     = r.AddMediaItemToTrack(temp_track)
  
      r.SetMediaItemInfo_Value(item, 'D_POSITION', t)
      r.SetMediaItemInfo_Value(item, 'D_LENGTH',   item_len)
      r.SetMediaItemInfo_Value(item, 'B_LOOPSRC',  0)
  
      local max_fade = item_len * 0.49
      r.SetMediaItemInfo_Value(item, 'D_FADEINLEN',  math.min(fade_len, max_fade))
      r.SetMediaItemInfo_Value(item, 'D_FADEOUTLEN', math.min(fade_len, max_fade))
      r.SetMediaItemInfo_Value(item, 'D_FADEINTYPE',  1)
      r.SetMediaItemInfo_Value(item, 'D_FADEOUTTYPE', 1)
  
      local take    = r.AddTakeToMediaItem(item)
            -- Guard: skip grain entirely if file is missing/moved since generate
            local file_ok = false
            local f = io.open(s.file, 'rb')
            if f then f:close(); file_ok = true end
      
            local new_src = file_ok and r.PCM_Source_CreateFromFile(s.file) or nil
            if new_src then
              r.SetMediaItemTake_Source(take, new_src)
        if reversed then
          r.SetMediaItemTakeInfo_Value(take, 'D_STARTOFFS', base_pos + grain_s)
          r.SetMediaItemTakeInfo_Value(take, 'D_PLAYRATE',  -rate)
        else
          r.SetMediaItemTakeInfo_Value(take, 'D_STARTOFFS', base_pos)
          r.SetMediaItemTakeInfo_Value(take, 'D_PLAYRATE',   rate)
        end
        table.insert(grain_items, item)
      else
        r.DeleteTrackMediaItem(temp_track, item)
      end
  
      t     = t + hop_s
      count = count + 1
    end

  -- 6. Glue grains
  r.SelectAllMediaItems(0, false)
  for _, item in ipairs(grain_items) do
    r.SetMediaItemSelected(item, true)
  end
  r.Main_OnCommand(40362, 0)

  -- 7. Restore crossfade setting
  if not xfade_was_on then r.Main_OnCommand(40041, 0) end

  r.UpdateArrange()
  r.UpdateTimeline()

  -- 8. Store range
  state.generated_start = win_start     -- changed from sel_start
  state.generated_end   = win_end       -- changed from sel_end
  state.has_glued_item  = true
  state.is_generating   = false
  state.status_msg = string.format(
    "Done — %d grains on '%s'", count, state.temp_track_name)

  r.PreventUIRefresh(-1)
  r.Undo_EndBlock("GrainWhoosh: Generate", -1)

  -- 9. Envelope deferred — outside undo block so REAPER state is stable
  r.defer(apply_whoosh_envelope)
end

function do_render()
  if not state.has_glued_item then return end

  local sws_cmd = r.NamedCommandLookup("_SWS_UNSELCHILDREN")
  local has_sws = sws_cmd ~= 0
  -- SWS is optional here — without it we just skip the child-unselect step.
  -- The render still works because we only select temp_track explicitly.

  -- ── Find temp track ───────────────────────────────────────────
  local temp_track = nil
  local temp_idx   = -1
  for i = 0, r.CountTracks(0) - 1 do
    local tr      = r.GetTrack(0, i)
    local _, name = r.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
    if name == state.temp_track_name then
      temp_track = tr
      temp_idx   = i
      break
    end
  end
  if not temp_track then
    state.status_msg = "Temp track not found — run Generate first"
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  -- ── Set time selection to generated range ─────────────────────
  local prev_ts_s, prev_ts_e = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  r.GetSet_LoopTimeRange(true, false, state.generated_start, state.generated_end, false)

  -- ── Create bounce track at the end ────────────────────────────
  -- This is the receiver for the send. It gets deleted at the end.
  local track_count = r.CountTracks(0)
  r.InsertTrackAtIndex(track_count, true)
  local bounce_track = r.GetTrack(0, track_count)

  -- ── Create send from temp track to bounce track ───────────────
  r.CreateTrackSend(temp_track, bounce_track)

  -- ── Select only bounce track, run render action ───────────────
  r.SetOnlyTrackSelected(bounce_track)

  -- 41716 = Track: Render selected area of tracks to stereo
  --         post-fader stem tracks (and mute originals)
  -- This renders THROUGH temp_track's full signal chain (including
  -- armed envelopes) into a new stem track, which is what we want.
  r.Main_OnCommand(41716, 0)

  -- ── Remove the send from temp_track ───────────────────────────
  local send_count = r.GetTrackNumSends(temp_track, 0)
  if send_count > 0 then
    r.RemoveTrackSend(temp_track, 0, send_count - 1)
  end

  -- ── Delete the bounce track (it was only a routing helper) ────
  r.DeleteTrack(bounce_track)

  -- ── The render action leaves a new stem track selected ────────
  -- with the rendered audio as a single item.
  local stem_track = r.GetSelectedTrack(0, 0)
  if stem_track then
    r.GetSetMediaTrackInfo_String(
      stem_track, 'P_NAME',
      state.temp_track_name .. "_render", true)
    -- Match channel count to source
    local nchan = state.is_mono and 1 or 2
    r.SetMediaTrackInfo_Value(stem_track, 'I_NCHAN', nchan)
    -- Unmute temp in case the render action muted it
    r.SetMediaTrackInfo_Value(temp_track, 'B_MUTE', 0)

    -- Move stem track right below temp track for easy comparison
    -- ReorderSelectedTracks needs the stem selected (it already is)
    -- and takes the target index (1-based, 0 = move to top).
    r.ReorderSelectedTracks(temp_idx + 1, 0)
  end

  -- ── Restore time selection ────────────────────────────────────
  r.GetSet_LoopTimeRange(true, false, prev_ts_s, prev_ts_e, false)

  state.status_msg = string.format(
    "Rendered — '%s_render' placed below temp track",
    state.temp_track_name)

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("GrainWhoosh: Render " .. state.temp_track_name, -1)
end

-- ── Main draw loop ──────────────────────────────────────────────
function draw()
  refresh_source_info()
  validate()

  r.ImGui_SetNextWindowSize(ctx, 380, 600, r.ImGui_Cond_FirstUseEver())
  local vis, open = r.ImGui_Begin(ctx, 'GrainWhoosh v0.9.0-beta', true,
      r.ImGui_WindowFlags_NoCollapse())

  if vis then

    section("Source", function()
      r.ImGui_Text(ctx, "Folder track")
      r.ImGui_SameLine(ctx, 110)
      r.ImGui_TextDisabled(ctx, state.folder_name)

      r.ImGui_Text(ctx, "Time selection")
      r.ImGui_SameLine(ctx, 110)
      if state.has_selection then
        r.ImGui_Text(ctx, string.format("%.2f – %.2f s", state.sel_start, state.sel_end))
      else
        r.ImGui_TextDisabled(ctx, "— no selection —")
      end

      r.ImGui_Text(ctx, "Child tracks")
      r.ImGui_SameLine(ctx, 110)
      r.ImGui_Text(ctx, tostring(state.child_count) .. " found")
    end)

    section("Grain", function()
      state.grain_size    = labeled_slider("Grain size",   state.grain_size,   10,  500, "%.0f ms")
      state.density       = labeled_slider("Density",      state.density,       0,    1, "%.2f")
      state.pitch_rnd     = labeled_slider("Pitch rnd",    state.pitch_rnd,     0,   12, "±%.1f st")
      state.pos_rnd       = labeled_slider("Pos rnd",      state.pos_rnd,       0,    1, "%.2f")
      state.reverse_rnd   = labeled_slider("Reverse rnd",  state.reverse_rnd,   0,    1, "%.2f")
      r.ImGui_Spacing(ctx)
      state.playback_mode = labeled_combo("Playback mode", state.playback_mode, PLAYBACK_MODES)
    end)

    section("Whoosh envelope", function()
          draw_envelope_preview()
          r.ImGui_Spacing(ctx)
          state.peak_pos        = labeled_slider("Peak position",    state.peak_pos,    0.01, 0.99, "%.2f")
          state.attack          = labeled_slider("Rise tension",     state.attack,     -1.0,  1.0,  "%.2f")
          state.release         = labeled_slider("Fall tension",     state.release,    -1.0,  1.0,  "%.2f")
          r.ImGui_Spacing(ctx)
          state.pitch_range     = labeled_slider("Pitch range",      state.pitch_range, 0,    24,   "%.1f st")
          state.pitch_direction = labeled_combo ("Pitch direction",  state.pitch_direction, PITCH_DIRS)
          state.pan_amount      = labeled_slider("Pan amount",       state.pan_amount,  0,    1.0,  "%.2f")
          state.pan_direction   = labeled_combo ("Pan direction",    state.pan_direction, PAN_DIRS)
        end)

    section("Output", function()
      r.ImGui_Text(ctx, "Temp track name")
      r.ImGui_SameLine(ctx, 120)
      r.ImGui_SetNextItemWidth(ctx, -1)
      local _, new_name = r.ImGui_InputText(ctx, '##tempname', state.temp_track_name)
      state.temp_track_name = new_name

      r.ImGui_Spacing(ctx)
      state.time_offset = labeled_slider("Edge inset", state.time_offset, 0, 0.45, "%.2f")
    end)

    -- Status bar
    r.ImGui_Separator(ctx)
    r.ImGui_Spacing(ctx)
    local dot_col = state.can_render and 0xFF44AA44 or 0xFF888888
    r.ImGui_TextColored(ctx, dot_col, "●")
    r.ImGui_SameLine(ctx)
    r.ImGui_TextDisabled(ctx, state.status_msg)
    r.ImGui_Spacing(ctx)

    -- Buttons — 2 rows × 3 columns
        local btn_w           = (r.ImGui_GetContentRegionAvail(ctx) - 16) / 3
        local gen_disabled    = not state.can_render
        local render_disabled = not state.has_glued_item
        local regen_disabled  = not (state.can_render and state.has_glued_item)
    
        -- Row 1: fresh generate (new seed on first call) + render
        if gen_disabled then r.ImGui_BeginDisabled(ctx) end
        if r.ImGui_Button(ctx, "Gen stereo", btn_w, 30) then
          state.is_mono = false
          do_generate(true)  -- treat each first-generate as a shuffle
        end
        if gen_disabled then r.ImGui_EndDisabled(ctx) end
    
        r.ImGui_SameLine(ctx)
    
        if gen_disabled then r.ImGui_BeginDisabled(ctx) end
        if r.ImGui_Button(ctx, "Gen mono", btn_w, 30) then
          state.is_mono = true
          do_generate(true)
        end
        if gen_disabled then r.ImGui_EndDisabled(ctx) end
    
        r.ImGui_SameLine(ctx)
    
        if render_disabled then r.ImGui_BeginDisabled(ctx) end
        if r.ImGui_Button(ctx, "Render", btn_w, 30) then
          do_render()
        end
        if render_disabled then r.ImGui_EndDisabled(ctx) end
    
        -- Row 2: regenerate with same seed + shuffle for new positions
        if regen_disabled then r.ImGui_BeginDisabled(ctx) end
        if r.ImGui_Button(ctx, "Regen stereo", btn_w, 26) then
          state.is_mono = false
          do_generate(false)  -- reuse existing seed
        end
        if regen_disabled then r.ImGui_EndDisabled(ctx) end
    
        r.ImGui_SameLine(ctx)
    
        if regen_disabled then r.ImGui_BeginDisabled(ctx) end
        if r.ImGui_Button(ctx, "Regen mono", btn_w, 26) then
          state.is_mono = true
          do_generate(false)
        end
        if regen_disabled then r.ImGui_EndDisabled(ctx) end
    
        r.ImGui_SameLine(ctx)
    
        if regen_disabled then r.ImGui_BeginDisabled(ctx) end
        if r.ImGui_Button(ctx, "Shuffle", btn_w, 26) then
          do_generate(true)  -- new seed, keep current mono/stereo mode
        end
        if regen_disabled then r.ImGui_EndDisabled(ctx) end
  end
  r.ImGui_End(ctx)
  return open
end

-- ── Run ─────────────────────────────────────────────────────────
function loop()
  local ok, open = pcall(draw)
  if not ok then
    r.ShowConsoleMsg("GrainWhoosh error: " .. tostring(open) .. "\n")
    return
  end
  if open then
    r.defer(loop)
  end
end

r.defer(loop)
