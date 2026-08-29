-- @description QikWhoosh
-- @author Ed
-- @version 1.0
-- @provides [main] .
-- @about
--   # QikWhoosh — Granular Whoosh Generator
--
--   A granular sound design tool built directly into REAPER. Your
--   session is the sample library — drop audio items onto child
--   tracks of a folder, make a time selection, and click Generate.
--
--   Requires:
--   - REAPER 6.x or newer
--   - ReaImGui (install via ReaPack)
--   - ReaPitch (ships with REAPER)
-- @changelog
--   v1.0
--   - Major rebuild of the QikWhoosh tool
--   - Improved UI and performance
--   - Added new features and enhancements
--   v0.9.1
--   - Fixed docking crash: ImGui_End() now only called when window is visible
--   - Added docking configuration support
--   v0.9.0
--   - Initial beta release

local r = reaper

if not r.ImGui_CreateContext then
  r.ShowMessageBox("This script requires ReaImGui.", "ReaImGui not found", 0)
  return
end
local ctx = r.ImGui_CreateContext("QikWhoosh")

-- ── Theme (mutable, RGBA format: 0xRRGGBBAA) ──
local theme = {
  WindowBg        = 0x1A1A1AFF,
  ChildBg         = 0x1A1A1AFF,
  PopupBg         = 0x202020FF,
  Border          = 0x444444FF,
  Separator       = 0x444444FF,
  Text            = 0xE0E0E0FF,
  TextDisabled    = 0x888888FF,
  Button          = 0x202020FF,
  ButtonHovered   = 0x333333FF,
  ButtonActive    = 0x2D6D8CFF,
  SliderGrab      = 0x2D6D8CFF,
  CheckMark       = 0x2D6D8CFF,
  Header          = 0x202020FF,
  HeaderHovered   = 0x2D6D8CFF,
  FrameBg         = 0x00000060,
  FrameBgHovered  = 0x00000080,
  WindowRounding  = 6,
  FrameRounding   = 4,
  GrabRounding    = 3,
  ItemSpacingX    = 8,
  ItemSpacingY    = 6,
  FramePaddingX   = 6,
  FramePaddingY   = 4,
  WindowPaddingX  = 10,
  WindowPaddingY  = 10,
}

local function push_theme()
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowPadding(), theme.WindowPaddingX, theme.WindowPaddingY)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), theme.FramePaddingX, theme.FramePaddingY)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), theme.ItemSpacingX, theme.ItemSpacingY)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowRounding(), theme.WindowRounding)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), theme.FrameRounding)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_GrabRounding(), theme.GrabRounding)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_WindowBg(),       theme.WindowBg)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ChildBg(),        theme.ChildBg)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_PopupBg(),        theme.PopupBg)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(),         theme.Border)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Separator(),      theme.Separator)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),           theme.Text)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TextDisabled(),   theme.TextDisabled)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),         theme.Button)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(),  theme.ButtonHovered)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(),   theme.ButtonActive)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_SliderGrab(),     theme.SliderGrab)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_CheckMark(),      theme.CheckMark)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Header(),         theme.Header)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_HeaderHovered(),  theme.HeaderHovered)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(),        theme.FrameBg)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgHovered(), theme.FrameBgHovered)
end

local function pop_theme()
  r.ImGui_PopStyleVar(ctx, 6)
  r.ImGui_PopStyleColor(ctx, 16)
end

-- ── UI Helpers ──
local function show_tooltip(text)
  if not text then return end
  if r.ImGui_IsItemHovered(ctx) then
    r.ImGui_BeginTooltip(ctx)
    r.ImGui_PushTextWrapPos(ctx, r.ImGui_GetFontSize(ctx) * 35.0)
    r.ImGui_Text(ctx, text)
    r.ImGui_PopTextWrapPos(ctx)
    r.ImGui_EndTooltip(ctx)
  end
end

local function section_header(label)
  if r.ImGui_SeparatorText then
    r.ImGui_SeparatorText(ctx, label)
  else
    r.ImGui_Text(ctx, label)
    r.ImGui_Separator(ctx)
  end
end

local PLAYBACK_MODES = {"Forward", "Reverse", "Ping-Pong", "Random"}
local SAMPLING_MODES = {"Uniform", "Sequential"}

-- Seed PRNG with wallclock + REAPER precise timer so each run differs
local function seed_random()
  math.randomseed(os.time() + math.floor((r.time_precise() % 1) * 1000000))
  math.random()  -- discard first value (poorly distributed in many Lua builds)
end

seed_random()

-- Initial State
local state = {
  -- Source / Sampling
  sampling_mode = 0, -- 0 = Uniform, 1 = Sequential
  grain_size = 80.0,   -- Uniform: 10-500ms grain length
  grain_density = 60.0,   -- 0-100 percentage (maps to density/crossfade)
  grain_pitch_rand = 0.0, -- 0..20 (% playback-rate variation per grain, Uniform)
  grain_vol_rand = 0.0,   -- 0..15 (% volume variation per grain, Uniform)
  playback_mode = 1, -- 1-based index for combo
  inset = 0.0,         -- 0..0.30 — compresses grain window from each side

  -- Source Info (from Reaper)
  sel_start = 0,
  sel_end = 0,
  sel_duration = 0,
  folder_track = nil,
  is_folder = false,
  child_count = 0,
  source_tracks = {},

  -- Envelope
  peak_pos = 0.5,
  hold_time = 0.0,
  attack = 0.5,
  release = 0.5,
  
  -- Doppler
  pitch_shift = 0.0,
  pitch_mode = 2,   -- 0=Full Range, 1=Semitones, 2=Cents, 3=Formant
  min_volume_db = -30.0,  -- -60..-20, floor for volume envelope
  filter_intensity = 0.5, -- 0..1 high-pass sweep depth (0 = bypassed)
  pan_amount = 1.0,
  pan_value = 0.0,  -- -1 (L→R) .. 0 (off) .. +1 (R→L)
  enable_doppler = true,
  
  -- Output / Generation
  temp_track_name = "GW_Temp",
  is_mono = false,
  generated_start = 0,
  generated_end = 0,
  status_msg = "Ready — select a folder and time range",
  is_generating = false,
  has_generated_item = false
}

-- Filter intensity (0..1) → high-pass edge cutoff in Hz (20 Hz .. 2 kHz, log)
local function filter_edge_hz(i)
  return 20.0 * (100.0 ^ math.max(0.0, math.min(1.0, i)))
end

-- Caches
local _track_cache = { track = nil, time = 0 }
local _fx_cache = {}
local DRAW_SEGMENTS = 24
local show_options = false

local viz_h = 200  -- shared fixed height for XY pad and visualizer

---------------------------------------------------------------------
-- UI Helper Functions
---------------------------------------------------------------------
function xy_pad(label, val_x, min_x, max_x, val_y, min_y, max_y, fmt_x, fmt_y, tooltip, label_x, label_y)
  local avail = r.ImGui_GetContentRegionAvail(ctx)
  local label_margin = 18  -- space for axis labels
  local pad = math.min(avail - label_margin - 4, 235)
  if pad < 80 then pad = 80 end
  local H = viz_h
  local dl = r.ImGui_GetWindowDrawList(ctx)

  -- Center the pad + label margin within the available width
  local total_w = pad + label_margin
  local offset_x = math.max(0, (avail - total_w) * 0.5)

  r.ImGui_Dummy(ctx, offset_x, 0)
  r.ImGui_SameLine(ctx)

  r.ImGui_InvisibleButton(ctx, '##xypad' .. label, pad, H)
  local active = r.ImGui_IsItemActive(ctx)
  local hovered = r.ImGui_IsItemHovered(ctx)
  local cx, cy = r.ImGui_GetItemRectMin(ctx)

  -- Background
  r.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + pad, cy + H, theme.FrameBg, 4)
  r.ImGui_DrawList_AddRect(dl, cx, cy, cx + pad, cy + H, theme.Border, 4)

  -- Grid lines (4x4)
  for i = 1, 3 do
    local gx = cx + (pad * i / 4)
    local gy = cy + (H * i / 4)
    r.ImGui_DrawList_AddLine(dl, gx, cy, gx, cy + H, 0x22AAAAAA, 1.0)
    r.ImGui_DrawList_AddLine(dl, cx, gy, cx + pad, gy, 0x22AAAAAA, 1.0)
  end

  -- Handle interaction
  if active then
    local mx, my = r.ImGui_GetMousePos(ctx)
    local fx = math.max(0, math.min(1, (mx - cx) / pad))
    local fy = math.max(0, math.min(1, 1.0 - (my - cy) / H))
    val_x = min_x + fx * (max_x - min_x)
    val_y = min_y + fy * (max_y - min_y)
  end

  -- Handle position
  local hx = cx + ((val_x - min_x) / (max_x - min_x)) * pad
  local hy = cy + (1.0 - (val_y - min_y) / (max_y - min_y)) * H

  -- Crosshair
  r.ImGui_DrawList_AddLine(dl, cx, hy, cx + pad, hy, 0x442D6D8C, 1.0)
  r.ImGui_DrawList_AddLine(dl, hx, cy, hx, cy + H, 0x442D6D8C, 1.0)

  -- Handle (glow + dot)
  r.ImGui_DrawList_AddCircleFilled(dl, hx, hy, 8, 0x332D6D8C)
  r.ImGui_DrawList_AddCircleFilled(dl, hx, hy, 5, 0xCC2D6D8C)
  r.ImGui_DrawList_AddCircleFilled(dl, hx, hy, 2, 0xFFFFFFFF)

  -- Value readout (small, in corners)
  r.ImGui_DrawList_AddText(dl, cx + 4, cy + H - 14, 0xFF888899,
    string.format(fmt_x, val_x))
  r.ImGui_DrawList_AddText(dl, cx + pad - 40, cy + 2, 0xFF888899,
    string.format(fmt_y, val_y))

  -- Axis labels inside the pad corners
  if label_y then
    r.ImGui_DrawList_AddText(dl, cx + 4, cy + 4, theme.TextDisabled, label_y)
  end
  if label_x then
    local x_txt_w = r.ImGui_CalcTextSize(ctx, label_x)
    r.ImGui_DrawList_AddText(dl, cx + pad - x_txt_w - 4, cy + H - 14, theme.TextDisabled, label_x)
  end

  if tooltip and (hovered or active) then
    show_tooltip(tooltip)
  end

  return val_x, val_y, active
end

function labeled_slider(label, value, min, max, format, default_val, tooltip)
  r.ImGui_Text(ctx, label)
  r.ImGui_SetNextItemWidth(ctx, -1)
  local changed, new_value = r.ImGui_SliderDouble(ctx, '##' .. label, value, min, max, format)
  if default_val ~= nil and r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
    return default_val
  end
  show_tooltip(tooltip)
  if changed then return new_value end
  return value
end

function labeled_combo(label, idx, items, tooltip)
  r.ImGui_Text(ctx, label)
  r.ImGui_SetNextItemWidth(ctx, -1)
  local changed, new_idx = r.ImGui_Combo(ctx, '##'..label, idx, table.concat(items, '\0')..'\0')
  show_tooltip(tooltip)
  if changed then return new_idx end
  return idx
end

local peak_dragging = false  -- tracks whether the peak position dot is being dragged
local peak_drag_start_my = 0  -- mouse Y at drag start
local peak_drag_start_hold = 0  -- hold_time at drag start
local rise_dragging = false  -- tracks whether the rise tension triangle is being dragged
local fall_dragging = false  -- tracks whether the fall tension triangle is being dragged
local filter_dragging = false     -- filter intensity knob (right edge)
local pitch_dragging = false
local dur_dragging = false
local pan_dragging = false

function draw_preview()
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local W = r.ImGui_GetContentRegionAvail(ctx)
  local H = viz_h

  -- InvisibleButton captures mouse events so the window isn't dragged
  -- when interacting with the visualizer. All drawing happens via the
  -- DrawList using the button's screen position.
  r.ImGui_InvisibleButton(ctx, '##preview', W, H)
  local cx, cy = r.ImGui_GetItemRectMin(ctx)
  local mx, my = r.ImGui_GetMousePos(ctx)
  local mouse_down = r.ImGui_IsMouseDown(ctx, 0)
  local mouse_clicked = r.ImGui_IsMouseClicked(ctx, 0)

  -- Pure black background
  r.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + W, cy + H, 0x000000FF, 4)
  r.ImGui_DrawList_AddRect(dl, cx, cy, cx + W, cy + H, theme.Border, 4)

  -- ── DURATION STRIP (top edge of visualizer) ──
  local dur_x0 = cx + 16
  local dur_x1 = cx + W - 16
  local dur_active_w = dur_x1 - dur_x0
  local dur_cy = cy + 10
  local dur_inset = math.max(0.0, math.min(0.30, state.inset))
  local dur_left = dur_x0 + dur_inset * dur_active_w
  local dur_right = dur_x1 - dur_inset * dur_active_w

  r.ImGui_DrawList_AddRectFilled(dl, dur_left, cy + 5, dur_right, cy + 15, 0x222D6D8C, 2)

  local dk_r = 5
  r.ImGui_DrawList_AddCircleFilled(dl, dur_left, dur_cy, dk_r + 2, 0x332D6D8C)
  r.ImGui_DrawList_AddCircleFilled(dl, dur_left, dur_cy, dk_r, theme.SliderGrab)
  r.ImGui_DrawList_AddCircleFilled(dl, dur_right, dur_cy, dk_r + 2, 0x332D6D8C)
  r.ImGui_DrawList_AddCircleFilled(dl, dur_right, dur_cy, dk_r, theme.SliderGrab)

  local dur_hit = my >= cy and my <= cy + 20 and mx >= dur_x0 and mx <= dur_x1
  if mouse_clicked and dur_hit and not peak_dragging and not rise_dragging and not fall_dragging and not pitch_dragging and not filter_dragging then
    dur_dragging = true
  end
  if not mouse_down then
    dur_dragging = false
  end
  if dur_dragging then
    local t = math.max(0, math.min(1, (mx - dur_x0) / dur_active_w))
    state.inset = math.max(0, math.min(0.30, math.min(t, 1 - t)))
  end
  if dur_hit or dur_dragging then
    show_tooltip("Trim front/back spill from the time selection.\nDrag left/right. Inner edges define the active region.")
  end

  -- ── DURATION SHADING (inset margins) ──
  local inset_frac = math.max(0.0, math.min(0.30, state.inset))
  local active_w = W * (1 - 2 * inset_frac)
  local margin_w = W * inset_frac
  if margin_w > 1 then
    r.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + margin_w, cy + H, 0x30000000, 0)
    r.ImGui_DrawList_AddRectFilled(dl, cx + W - margin_w, cy, cx + W, cy + H, 0x30000000, 0)
  end

  -- ── ENVELOPE MATH (computed first so dots can use it) ──
  local att = math.max(-1.0, math.min(1.0, state.attack))
  local rel = math.max(-1.0, math.min(1.0, state.release))
  local dur = math.max(0.001, state.sel_end - state.sel_start)

  local function bez(t, v0, v1, tension_a, tension_b)
    local c0 = v0 + (v1 - v0) * (0.33 + tension_a * 0.33)
    local c1 = v1 - (v1 - v0) * (0.33 - tension_b * 0.33)
    local u = 1 - t
    return u*u*u * v0 + 3 * u*u*t * c0 + 3 * u*t*t * c1 + t*t*t * v1
  end

  local hold = state.hold_time
  local peak_start = math.max(0, math.min(1.0 - hold, state.peak_pos - hold / 2))
  local peak_end = math.min(1.0, peak_start + hold)

  local function vol_fn(t)
    if t <= peak_start then
      local lt = (peak_start > 0) and (t / peak_start) or 0
      return bez(lt, 0, 1, att, att)
    elseif t >= peak_end then
      local lt = (peak_end < 1) and ((t - peak_end) / (1 - peak_end)) or 0
      return bez(lt, 1, 0, -rel, -rel)
    else
      return 1.0
    end
  end

  -- Pitch curve function: ends anchored at the middle line (0.5),
  -- only the peak deviates up/down by pitch_shift. This mirrors the
  -- actual ReaPitch envelope written by write_doppler_env (floor/peak/floor).
  -- pitch_shift > 0 = pitch rises to peak then falls (approach)
  -- pitch_shift < 0 = pitch dips to peak then rises (recede)
  local pitch_fn
  if state.pitch_shift ~= 0 then
    local pshift = state.pitch_shift / 12.0  -- normalize to -1..1
    pitch_fn = function(t)
      local v = vol_fn(t)                 -- 0..1 volume shape
      return 0.5 + v * 0.5 * pshift      -- 0.5 at edges, 0.5±0.5*pshift at peak
    end
  end

  -- ── DIAMOND BODY ──
  -- Silhouette built by mirroring the volume envelope around the midline:
  -- top edge = +vol_fn, bottom edge = -vol_fn. Responds to peak position,
  -- hold time, rise/fall tension, and inset.
  r.ImGui_DrawList_PushClipRect(dl, cx, cy, cx + W, cy + H, true)
  local cy_mid = cy + H * 0.5
  -- Reserve vertical space so the body clears the duration strip (top ~20px)
  -- and the pan strip (bottom ~20px)
  local half_h = H * 0.5 - 24

  local fill_col = 0x4488CC38
  local line_col = 0x4488CCCC

  -- Sample the envelope across the active (inset-trimmed) window
  local SEG = 64
  local top_pts, bot_pts = {}, {}
  for i = 0, SEG do
    local t = i / SEG
    local v = math.max(0, math.min(1, vol_fn(t)))
    local x = cx + margin_w + t * active_w
    top_pts[#top_pts + 1] = x
    top_pts[#top_pts + 1] = cy_mid - v * half_h
    bot_pts[#bot_pts + 1] = x
    bot_pts[#bot_pts + 1] = cy_mid + v * half_h
  end

  -- Fill: two triangles per segment (robust for bowed/non-convex curves)
  for i = 1, SEG do
    local t0x, t0y = top_pts[i * 2 - 1], top_pts[i * 2]
    local t1x, t1y = top_pts[i * 2 + 1], top_pts[i * 2 + 2]
    local b0x, b0y = bot_pts[i * 2 - 1], bot_pts[i * 2]
    local b1x, b1y = bot_pts[i * 2 + 1], bot_pts[i * 2 + 2]
    r.ImGui_DrawList_AddTriangleFilled(dl, t0x, t0y, b0x, b0y, t1x, t1y, fill_col)
    r.ImGui_DrawList_AddTriangleFilled(dl, t1x, t1y, b0x, b0y, b1x, b1y, fill_col)
  end

  -- Outline: closed loop (top edge forward, bottom edge backward, back to start)
  local outline = {}
  for i = 1, #top_pts do outline[#outline + 1] = top_pts[i] end
  for i = #bot_pts - 1, 1, -2 do
    outline[#outline + 1] = bot_pts[i]
    outline[#outline + 1] = bot_pts[i + 1]
  end
  outline[#outline + 1] = top_pts[1]
  outline[#outline + 1] = top_pts[2]
  r.ImGui_DrawList_AddPolyline(dl, r.new_array(outline), line_col, 0, 2.0)
  r.ImGui_DrawList_PopClipRect(dl)

  -- ── PITCH CURVE (white line, only when pitch_shift ≠ 0) ──
  if pitch_fn then
    local pts_pitch = {}
    local segments = 80
    for i = 0, segments do
      local t = i / segments
      local x = cx + t * W
      local v = pitch_fn(t)
      pts_pitch[#pts_pitch+1] = x
      pts_pitch[#pts_pitch+1] = cy + H - v * (H - 8) - 4
    end
    local arr_p = r.new_array(pts_pitch)
    r.ImGui_DrawList_AddPolyline(dl, arr_p, 0x44FFFFFF, 0, 3.0)
    r.ImGui_DrawList_AddPolyline(dl, arr_p, 0xCCFFFFFF, 0, 1.0)
  end

  -- ── FILTER CURVE (fixed log ramp; green) ──
  -- Bottom-left anchored. The curve always rises with the same log shape
  -- and tops out at x = intensity * W: near the left edge at low
  -- intensity, at the right edge at maximum, then flat along the top.
  -- Hidden at intensity 0 (filter bypassed).
  -- Colors 0xRRGGBBAA, shared with the right-edge knob below.
  local filt_col  = 0x40E080FF  -- bright green (knob, opaque)
  local filt_line = 0x40E080CC
  local filt_glow = 0x40E08044
  local function filt_int_to_y(i)
    return cy + 6 + (1 - i) * (H - 12)
  end
  if state.filter_intensity > 0.001 then
    local KLOG = 4.0  -- fixed log curvature
    local ek = math.exp(KLOG) - 1.0
    local reach = math.max(0.03, state.filter_intensity)  -- top-out point (fraction of W)
    local y_top, y_bot = filt_int_to_y(1), filt_int_to_y(0)
    local fpts = {}
    local FSEG = 64
    for i = 0, FSEG do
      local t = i / FSEG
      local u = math.min(1.0, t / reach)
      local v = math.log(1.0 + ek * u) / KLOG
      fpts[#fpts + 1] = cx + t * W
      fpts[#fpts + 1] = y_bot + v * (y_top - y_bot)
    end
    local farr = r.new_array(fpts)
    r.ImGui_DrawList_AddPolyline(dl, farr, filt_glow, 0, 3.0)
    r.ImGui_DrawList_AddPolyline(dl, farr, filt_line, 0, 1.5)
  end

  -- (Spill lines are drawn after the peak dot — they need its position)

  -- ── PEAK POSITION DOT (draggable: X = peak pos, Y = hold time) ──
  local peak_dot_x = cx + state.peak_pos * W
  local peak_dot_y = cy + H * 0.5
  local peak_dot_ry = 8
  local peak_dot_rx = 8 + state.hold_time * 80  -- width grows with hold time (0..0.5 → 8..48)
  -- Hit test against the ellipse (approximate with bounding box + a little padding)
  local hit_dx = math.abs(mx - peak_dot_x)
  local hit_dy = math.abs(my - peak_dot_y)
  local on_dot = (hit_dx < peak_dot_rx + 4) and (hit_dy < peak_dot_ry + 4)

  -- Start dragging if mouse pressed on the dot
  if mouse_clicked and on_dot then
    peak_dragging = true
    peak_drag_start_my = my
    peak_drag_start_hold = state.hold_time
  end
  -- Stop dragging when mouse released
  if not mouse_down then
    peak_dragging = false
  end
  -- Update peak_pos (horizontal) and hold_time (vertical, relative) while dragging
  if peak_dragging then
    local new_t = (mx - cx) / W
    state.peak_pos = math.max(0.01, math.min(0.99, new_t))
    peak_dot_x = cx + state.peak_pos * W

    -- Vertical drag adjusts hold time relative to drag start.
    -- Dragging up increases, down decreases. Full canvas height = 0.5 range.
    local drag_delta = peak_drag_start_my - my  -- positive = up
    local hold_delta = (drag_delta / H) * 0.5
    state.hold_time = math.max(0.0, math.min(0.5, peak_drag_start_hold + hold_delta))
    peak_dot_rx = 8 + state.hold_time * 80
  end

  -- Draw the peak dot as an ellipse (gold, glowy)
  r.ImGui_DrawList_AddEllipseFilled(dl, peak_dot_x, peak_dot_y, peak_dot_rx + 4, peak_dot_ry + 4, 0x332D6D8C)  -- outer glow
  r.ImGui_DrawList_AddEllipseFilled(dl, peak_dot_x, peak_dot_y, peak_dot_rx,     peak_dot_ry,     0xFF2D6D8C)  -- body
  r.ImGui_DrawList_AddEllipseFilled(dl, peak_dot_x, peak_dot_y, peak_dot_rx - 4, peak_dot_ry - 4, 0xFF33A07C)  -- highlight
  if on_dot or peak_dragging then
    show_tooltip("Peak position and hold time.\nDrag horizontally to move the peak.\nDrag vertically to adjust hold time.\nUp = longer hold, Down = shorter hold.")
  end

  -- Small directional triangles around the dot (up/down only)
  local arr_col = 0xFF33A07C
  local arr_s = 4  -- triangle size
  local arr_off = peak_dot_ry + 6  -- distance from dot center
  -- Up: ▲
  r.ImGui_DrawList_AddTriangleFilled(dl,
    peak_dot_x, peak_dot_y - arr_off - arr_s,
    peak_dot_x - arr_s, peak_dot_y - arr_off + arr_s,
    peak_dot_x + arr_s, peak_dot_y - arr_off + arr_s, arr_col)
  -- Down: ▼
  r.ImGui_DrawList_AddTriangleFilled(dl,
    peak_dot_x, peak_dot_y + arr_off + arr_s,
    peak_dot_x - arr_s, peak_dot_y + arr_off - arr_s,
    peak_dot_x + arr_s, peak_dot_y + arr_off - arr_s, arr_col)

  -- ── RISE TENSION TRIANGLE (draggable, horizontal only) ──
  -- Sits in the rise region (left edge to peak dot). < points left.
  -- Near peak (right) = sharp (1.0), far from peak (left) = relaxed (-1.0).
  local gap = 20  -- clear space around the peak dot
  local rise_margin = 16  -- keep triangle inside the box
  local rise_region_x0 = cx + rise_margin
  local rise_region_w = (peak_dot_x - peak_dot_rx) - gap - rise_region_x0
  -- Position: attack=-1.0 → far left, attack=1.0 → near peak (right)
  local rise_tri_x = rise_region_x0 + ((1.0 - state.attack) / 2.0) * rise_region_w
  local rise_tri_y = peak_dot_y
  local rise_tri_s = 8  -- triangle size
  local rise_hit = math.abs(mx - rise_tri_x) < rise_tri_s + 4 and math.abs(my - rise_tri_y) < rise_tri_s + 4

  if mouse_clicked and rise_hit and not peak_dragging then
    rise_dragging = true
  end
  if not mouse_down then
    rise_dragging = false
  end
  if rise_dragging then
    local new_t = (mx - rise_region_x0) / rise_region_w
    new_t = math.max(0, math.min(1, new_t))
    -- new_t=0 (left) → 1.0 (sharp), new_t=1 (right, near peak) → -1.0 (relaxed)
    state.attack = 1.0 - (new_t * 2.0)
    rise_tri_x = rise_region_x0 + ((1.0 - state.attack) / 2.0) * rise_region_w
  end

  -- Draw the < triangle (gold, glowy)
  local p1x, p1y = rise_tri_x - rise_tri_s, rise_tri_y           -- left point
  local p2x, p2y = rise_tri_x + rise_tri_s, rise_tri_y - rise_tri_s  -- top right
  local p3x, p3y = rise_tri_x + rise_tri_s, rise_tri_y + rise_tri_s  -- bottom right
  r.ImGui_DrawList_AddTriangleFilled(dl, p1x, p1y, p2x, p2y, p3x, p3y, 0x332D6D8C)  -- glow (bigger)
  local gs = rise_tri_s + 3
  r.ImGui_DrawList_AddTriangleFilled(dl, rise_tri_x - gs, rise_tri_y, rise_tri_x + gs, rise_tri_y - gs, rise_tri_x + gs, rise_tri_y + gs, 0x332D6D8C)
  r.ImGui_DrawList_AddTriangleFilled(dl, p1x, p1y, p2x, p2y, p3x, p3y, 0xFF2D6D8C)  -- body
  r.ImGui_DrawList_AddTriangleFilled(dl, rise_tri_x - rise_tri_s + 3, rise_tri_y, rise_tri_x + rise_tri_s - 3, rise_tri_y - rise_tri_s + 4, rise_tri_x + rise_tri_s - 3, rise_tri_y + rise_tri_s - 4, 0xFF33A07C)  -- highlight
  if rise_hit or rise_dragging then
    show_tooltip("Rise tension (attack curvature).\nDrag left = sharp attack.\nDrag right = gradual attack.")
  end

  -- ── FALL TENSION TRIANGLE (draggable, horizontal only) ──
  -- Sits in the fall region (peak dot to right edge). > points right.
  -- Near peak (left) = sharp (1.0), far from peak (right) = relaxed (-1.0).
  local fall_margin = 16  -- keep triangle inside the box
  local fall_region_start = peak_dot_x + peak_dot_rx + gap
  local fall_region_end = cx + W - fall_margin
  local fall_region_w = fall_region_end - fall_region_start
  -- Position: release=-1.0 → near peak (left), release=1.0 → far right
  local fall_tri_x = fall_region_start + ((state.release + 1.0) / 2.0) * fall_region_w
  local fall_tri_y = peak_dot_y
  local fall_tri_s = 8
  local fall_hit = math.abs(mx - fall_tri_x) < fall_tri_s + 4 and math.abs(my - fall_tri_y) < fall_tri_s + 4

  if mouse_clicked and fall_hit and not peak_dragging and not rise_dragging then
    fall_dragging = true
  end
  if not mouse_down then
    fall_dragging = false
  end
  if fall_dragging then
    local new_t = (mx - fall_region_start) / fall_region_w
    new_t = math.max(0, math.min(1, new_t))
    -- new_t=0 (left, near peak) → -1.0, new_t=1 (right, far) → 1.0
    state.release = (new_t * 2.0) - 1.0
    fall_tri_x = fall_region_start + ((state.release + 1.0) / 2.0) * fall_region_w
  end

  -- Draw the > triangle (gold, glowy)
  local fp1x, fp1y = fall_tri_x + fall_tri_s, fall_tri_y            -- right point
  local fp2x, fp2y = fall_tri_x - fall_tri_s, fall_tri_y - fall_tri_s  -- top left
  local fp3x, fp3y = fall_tri_x - fall_tri_s, fall_tri_y + fall_tri_s  -- bottom left
  local fgs = fall_tri_s + 3
  r.ImGui_DrawList_AddTriangleFilled(dl, fall_tri_x + fgs, fall_tri_y, fall_tri_x - fgs, fall_tri_y - fgs, fall_tri_x - fgs, fall_tri_y + fgs, 0x332D6D8C)
  r.ImGui_DrawList_AddTriangleFilled(dl, fp1x, fp1y, fp2x, fp2y, fp3x, fp3y, 0xFF2D6D8C)  -- body
  r.ImGui_DrawList_AddTriangleFilled(dl, fall_tri_x + fall_tri_s - 3, fall_tri_y, fall_tri_x - fall_tri_s + 3, fall_tri_y - fall_tri_s + 4, fall_tri_x - fall_tri_s + 3, fall_tri_y + fall_tri_s - 4, 0xFF33A07C)  -- highlight
  if fall_hit or fall_dragging then
    show_tooltip("Fall tension (release curvature).\nDrag right = sharp release.\nDrag left = gradual release.")
  end

  -- ── PITCH KNOB (left edge of visualizer) ──
  local p_knob_x = cx + 8
  local p_inset = 5
  local function p_val_to_y(v) return cy + p_inset + ((12 - v) / 24) * (H - 2 * p_inset) end
  local function p_y_to_val(y) return math.max(-12, math.min(12, ((cy + H - p_inset - y) / (H - 2 * p_inset)) * 24 - 12)) end
  local p_knob_y = p_val_to_y(state.pitch_shift)
  local p_hit = math.abs(mx - p_knob_x) < 8 and math.abs(my - p_knob_y) < 8

  if mouse_clicked and p_hit and not peak_dragging and not rise_dragging and not fall_dragging then
    pitch_dragging = true
  end
  if not mouse_down then
    pitch_dragging = false
  end
  if pitch_dragging then
    state.pitch_shift = p_y_to_val(my)
    if math.abs(state.pitch_shift) < 0.5 then state.pitch_shift = 0.0 end
    p_knob_y = p_val_to_y(state.pitch_shift)
  end
  if p_hit and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
    state.pitch_shift = 0.0
  end

  r.ImGui_DrawList_AddCircleFilled(dl, p_knob_x, p_knob_y, p_inset, 0xFF2D6D8C)
  r.ImGui_DrawList_AddCircleFilled(dl, p_knob_x, p_knob_y, 2, 0xFF33A07C)

  if p_hit or pitch_dragging then
    show_tooltip("Pitch shift at the envelope peak (semitones).\n+ = pitch rises then falls (approach)\n- = pitch dips then rises (recede)\n0 = no pitch envelope\nDrag up/down. Double-click to reset.")
  end

  -- ── PAN STRIP (bottom edge of visualizer) ──
  local pan_x0 = cx + 16
  local pan_x1 = cx + W - 16
  local pan_active_w = pan_x1 - pan_x0
  local pan_cy = cy + H - 10
  local pkx = pan_x0 + (state.pan_value + 1.0) * 0.5 * pan_active_w

  local pan_hit = my >= cy + H - 20 and my <= cy + H and mx >= pan_x0 and mx <= pan_x1
  local pan_knob_hit = math.abs(mx - pkx) < 16 and math.abs(my - pan_cy) < 10
  if mouse_clicked and pan_hit and not dur_dragging and not peak_dragging and not rise_dragging and not fall_dragging and not pitch_dragging then
    pan_dragging = true
  end
  if not mouse_down then
    pan_dragging = false
  end
  if pan_dragging then
    local t = math.max(0.0, math.min(1.0, (mx - pan_x0) / pan_active_w))
    local raw = t * 2.0 - 1.0
    state.pan_value = math.abs(raw) < 0.06 and 0.0 or raw
  end
  if pan_hit and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
    state.pan_value = 0.0
  end

  if math.abs(state.pan_value) < 0.06 then
    local ear_r = 2.2
    local head_r = 4.6
    local edx = head_r + ear_r - 0.5
    r.ImGui_DrawList_AddCircleFilled(dl, pkx - edx, pan_cy, ear_r, theme.SliderGrab)
    r.ImGui_DrawList_AddCircleFilled(dl, pkx,       pan_cy, head_r, theme.SliderGrab)
    r.ImGui_DrawList_AddCircleFilled(dl, pkx + edx, pan_cy, ear_r, theme.SliderGrab)
  else
    local s = 5.5
    local dx = s * 1.7
    local pr = state.pan_value <= 0.0
    for i = -1, 1 do
      local tx = pkx + i * dx
      if pr then
        r.ImGui_DrawList_AddTriangleFilled(dl, tx + s, pan_cy, tx - s, pan_cy - s, tx - s, pan_cy + s, theme.SliderGrab)
      else
        r.ImGui_DrawList_AddTriangleFilled(dl, tx - s, pan_cy, tx + s, pan_cy - s, tx + s, pan_cy + s, theme.SliderGrab)
      end
    end
  end

  if pan_knob_hit or pan_dragging then
    show_tooltip("Center = no pan sweep.\nLeft = L->R sweep.\nRight = R->L sweep.\nEdges = 100% strength.\nDouble-click to reset.")
  end

  -- ── FILTER INTENSITY KNOB (right edge of visualizer) ──
  -- Vertical drag sets the sweep depth; the knob rides the start-freq line.
  -- The sweep always opens to fully-pass at the whoosh peak (bottom edge).
  local f_knob_x = cx + W - 8
  local f_inset = 6

  local fi_y = filt_int_to_y(state.filter_intensity)

  -- Sweep-range bar: knob down to the bottom edge (= fully open at the peak)
  r.ImGui_DrawList_AddRectFilled(dl, f_knob_x - 2, fi_y, f_knob_x + 2, filt_int_to_y(0), 0x40E08022, 1)

  local f_hit = math.abs(mx - f_knob_x) < 10 and math.abs(my - fi_y) < 8
  if mouse_clicked and f_hit and not dur_dragging and not pan_dragging and not pitch_dragging and not peak_dragging and not rise_dragging and not fall_dragging then
    filter_dragging = true
  end
  if not mouse_down then
    filter_dragging = false
  end
  if filter_dragging then
    state.filter_intensity = math.max(0.0, math.min(1.0, 1.0 - (my - cy - 6) / (H - 12)))
    if state.filter_intensity < 0.02 then state.filter_intensity = 0.0 end
    fi_y = filt_int_to_y(state.filter_intensity)
  end
  if f_hit and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
    state.filter_intensity = 0.0
    fi_y = filt_int_to_y(0)
  end

  r.ImGui_DrawList_AddCircleFilled(dl, f_knob_x, fi_y, f_inset, filt_col)
  r.ImGui_DrawList_AddCircleFilled(dl, f_knob_x, fi_y, 3, 0xFFFFFFFF)

  if f_hit or filter_dragging then
    local tip
    if state.filter_intensity <= 0.0 then
      tip = "Filter intensity: 0% (high-pass bypassed)\nDrag up to add a sweep. Double-click resets."
    else
      tip = string.format("Filter intensity: %.0f%%\nHigh-pass starts at %.0f Hz at the edges,\nopens fully at the peak. Double-click resets.",
        state.filter_intensity * 100, filter_edge_hz(state.filter_intensity))
    end
    show_tooltip(tip)
  end

  -- ── HOVER READOUT ──
  if not peak_dragging and not rise_dragging and not fall_dragging and not pitch_dragging and not filter_dragging and not dur_dragging and not pan_dragging and mx >= cx and mx <= cx + W and my >= cy and my <= cy + H then
    local hover_t = (mx - cx) / W
    hover_t = math.max(0, math.min(1, hover_t))
    local hover_x = cx + hover_t * W

    r.ImGui_DrawList_AddLine(dl, hover_x, cy, hover_x, cy + H, 0x88FFFFFF, 1.0)

    local hv_vol = math.max(0, math.min(1, vol_fn(hover_t)))
    local time_s = hover_t * dur
    r.ImGui_DrawList_AddText(dl, hover_x + 8, my - 30, 0xFFCCCCCC,
      string.format("%.2fs\nVol: %.0f%%", time_s, hv_vol * 100))
  end
end

---------------------------------------------------------------------
-- Reaper Data Functions
---------------------------------------------------------------------
function refresh_source_info()
  -- Reset
  state.child_count = 0
  state.folder_track = nil
  state.is_folder = false
  state.source_tracks = {}

  -- Get time selection
  local ts, te = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  state.sel_start = ts
  state.sel_end = te
  state.sel_duration = te - ts

  -- Get selected track
  local sel_track = r.GetSelectedTrack(0, 0)
  if not sel_track then return end

  -- Check if it's a folder
  local folder_depth = r.GetMediaTrackInfo_Value(sel_track, 'I_FOLDERDEPTH')
  
  if folder_depth == 1 then
    state.folder_track = sel_track
    state.is_folder = true

    local track_num = r.GetMediaTrackInfo_Value(sel_track, 'IP_TRACKNUMBER')
    local folder_0based_idx = track_num - 1
    local total_tracks = r.CountTracks(0)
    
    for i = folder_0based_idx + 1, total_tracks - 1 do
      local child_track = r.GetTrack(0, i)
      if not child_track then break end
      
      local child_depth = r.GetMediaTrackInfo_Value(child_track, 'I_FOLDERDEPTH')
      if child_depth < 0 then break end

      if r.CountTrackMediaItems(child_track) > 0 then
        state.child_count = state.child_count + 1
        state.source_tracks[#state.source_tracks + 1] = child_track
      end
    end
  end
end

---------------------------------------------------------------------
-- Settings Persistence
---------------------------------------------------------------------
local SETTINGS_SECTION = "QikWhoosh"

function save_settings()
  local data = {
    sampling_mode = state.sampling_mode,
    grain_size = state.grain_size,
    grain_density = state.grain_density,
    grain_pitch_rand = state.grain_pitch_rand,
    grain_vol_rand = state.grain_vol_rand,
    playback_mode = state.playback_mode,
    inset = state.inset,
    peak_pos = state.peak_pos,
    hold_time = state.hold_time,
    attack = state.attack,
    release = state.release,
    pitch_shift = state.pitch_shift,
    pitch_mode = state.pitch_mode,
    min_volume_db = state.min_volume_db,
    filter_intensity = state.filter_intensity,
    pan_amount = state.pan_amount,
    pan_value = state.pan_value,
    enable_doppler = state.enable_doppler,
    temp_track_name = state.temp_track_name,
    is_mono = state.is_mono,
  }
  local str = ""
  for k, v in pairs(data) do
    local val = tostring(v)
    if type(v) == "boolean" then val = v and "1" or "0" end
    str = str .. k .. "=" .. val .. "|"
  end
  r.SetExtState(SETTINGS_SECTION, "state", str, true)
end

function load_settings()
  local str = r.GetExtState(SETTINGS_SECTION, "state")
  if str == "" then return end
  for k, v in string.gmatch(str, "([^=]+)=([^|]+)|") do
    if state[k] ~= nil then
      if type(state[k]) == "boolean" then
        state[k] = (v == "1")
      elseif type(state[k]) == "number" then
        state[k] = tonumber(v) or state[k]
      else
        state[k] = v
      end
    end
  end
end

---------------------------------------------------------------------
-- Generation Functions
---------------------------------------------------------------------
function validate_can_generate()
  if not state.is_folder then
    state.status_msg = "Error — select a folder track"
    return false
  end
  if state.child_count == 0 then
    state.status_msg = "Error — no valid source tracks"
    return false
  end
  if state.sel_duration <= 0 then
    state.status_msg = "Error — make a time selection"
    return false
  end
  if state.is_generating then
    return false
  end
  return true
end

function find_temp_track()
  local now = r.time_precise()
  if _track_cache.track and now - _track_cache.time < 0.5 then
    local cached = _track_cache.track
    local _, cached_name = r.GetSetMediaTrackInfo_String(cached, 'P_NAME', '', false)
    if cached_name == state.temp_track_name then
      local idx = r.GetMediaTrackInfo_Value(cached, 'IP_TRACKNUMBER') - 1
      return cached, idx
    end
  end
  for i = 0, r.CountTracks(0) - 1 do
    local track = r.GetTrack(0, i)
    local _, name = r.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)
    if name == state.temp_track_name then
      _track_cache = { track = track, time = now }
      return track, i
    end
  end
  return nil, nil
end

function get_unique_temp_name()
  local base_name = state.temp_track_name
  -- Remove any existing number suffix
  base_name = base_name:gsub("_%d+$", "")
  
  local counter = 1
  local unique_name = base_name
  
  while true do
    local exists = false
    for i = 0, r.CountTracks(0) - 1 do
      local track = r.GetTrack(0, i)
      local _, name = r.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)
      if name == unique_name then
        exists = true
        break
      end
    end
    if not exists then break end
    unique_name = base_name .. "_" .. counter
    counter = counter + 1
  end
  
  return unique_name
end

function do_generate(is_mono, apply_env)
  if not validate_can_generate() then return end
  if apply_env == nil then apply_env = true end

  seed_random()  -- fresh grain layout every preview

  state.is_generating = true
  state.status_msg = "Generating..."

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  local existing_track, _ = find_temp_track()
  if existing_track then
    r.DeleteTrack(existing_track)
  end
  
  -- Ensure unique temp track name (stale GW_Track leftover can collide)
  local unique_name = get_unique_temp_name()
  state.temp_track_name = unique_name
  
  r.InsertTrackAtIndex(0, true)
  local temp_track = r.GetTrack(0, 0)
  r.GetSetMediaTrackInfo_String(temp_track, 'P_NAME', unique_name, true)
  r.SetMediaTrackInfo_Value(temp_track, 'I_NCHAN', is_mono and 1 or 2)
  
  -- Force auto-crossfade on so grain edges blend
  local xfade_was_on = r.GetToggleCommandState(40041) == 1
  if not xfade_was_on then r.Main_OnCommand(40041, 0) end
  
  -- Get time selection with edge compression
  local inset = math.max(0.0, math.min(0.30, state.inset))
  local inset_s = state.sel_duration * inset
  local win_start = state.sel_start + inset_s
  local win_end = state.sel_end - inset_s
  local win_dur = math.max(0.001, win_end - win_start)
  
  local source_tracks = state.source_tracks
  
  local grain_items = {}
  local count = 0
  
  local density_normalized = state.grain_density / 100
  
  if state.sampling_mode == 1 then -- Sequential
    -- Build playback order based on direction
    local num_sources = math.min(10, #source_tracks)
    local order = {}
    local mode = state.playback_mode
    
    if mode == 1 then
      -- Forward: 1, 2, 3, 4...
      for i = 1, num_sources do order[i] = i end
    elseif mode == 2 then
      -- Reverse: ..., 4, 3, 2, 1
      for i = 1, num_sources do order[i] = num_sources - i + 1 end
    elseif mode == 3 then
      -- Ping-Pong: 1, last, 2, second-last...
      local left, right = 1, num_sources
      local idx = 1
      while left <= right do
        if left == right then
          order[idx] = left
        else
          order[idx] = left
          order[idx + 1] = right
          idx = idx + 1
        end
        left = left + 1
        right = right - 1
        idx = idx + 1
      end
    else
      -- Random: shuffle but each track once
      for i = 1, num_sources do order[i] = i end
      for i = num_sources, 2, -1 do
        local j = math.random(1, i)
        order[i], order[j] = order[j], order[i]
      end
    end
    
    -- Auto-calculate grain size to fit all sources once in time selection
    local total_grains = #order
    local grain_s = win_dur / total_grains
    local crossfade_s = grain_s * density_normalized * 0.5
    local item_len = grain_s + crossfade_s
    
    local t = win_start
    for i = 1, #order do
      -- Every source gets its slot; the tail slice is clamped to fit below.
      if t >= win_end then break end
      
      local track = source_tracks[order[i]]
      if not track then break end
      
      local item = r.GetTrackMediaItem(track, 0)
      if item then
        local take = r.GetActiveTake(item)
        if take then
          local source = r.GetMediaItemTake_Source(take)
          if source then
            -- Clamp the final slice so it can't spill past the window
            local this_len = math.min(item_len, win_end - t)
            local new_item = r.AddMediaItemToTrack(temp_track)
            r.SetMediaItemInfo_Value(new_item, 'D_POSITION', t)
            r.SetMediaItemInfo_Value(new_item, 'D_LENGTH', this_len)
            r.SetMediaItemInfo_Value(new_item, 'B_LOOPSRC', 0)
            
            local max_fade = this_len * 0.49
            r.SetMediaItemInfo_Value(new_item, 'D_FADEINLEN', math.min(crossfade_s, max_fade))
            r.SetMediaItemInfo_Value(new_item, 'D_FADEOUTLEN', math.min(crossfade_s, max_fade))
            r.SetMediaItemInfo_Value(new_item, 'D_FADEINTYPE', 1)
            r.SetMediaItemInfo_Value(new_item, 'D_FADEOUTTYPE', 1)
            
            local new_take = r.AddTakeToMediaItem(new_item)
            r.SetMediaItemTake_Source(new_take, source)
            r.SetMediaItemTakeInfo_Value(new_take, 'D_STARTOFFS', 0.0)
            
            table.insert(grain_items, new_item)
            count = count + 1
          end
        end
      end
      t = t + grain_s
    end
    
  else -- Uniform (layered: each item = full pass → glue → one layer)
    local grain_s_base = state.grain_size / 1000.0
    local mode = state.playback_mode
    
    for src_idx = 1, #source_tracks do
      if count >= 2000 then break end
      local track = source_tracks[src_idx]
      local num_ti = r.CountTrackMediaItems(track)
      for ti = 0, num_ti - 1 do
        if count >= 2000 then break end
        local src_item = r.GetTrackMediaItem(track, ti)
        local sip = r.GetMediaItemInfo_Value(src_item, 'D_POSITION')
        local sil = r.GetMediaItemInfo_Value(src_item, 'D_LENGTH')
        if sip < win_end and sip + sil > win_start then
          local take = r.GetActiveTake(src_item)
          if take then
            local source = r.GetMediaItemTake_Source(take)
            if source then
              local source_len = r.GetMediaSourceLength(source)
              local layer_items = {}
              local t = win_start
              local read_head = 0.0
              
              while t < win_end and #layer_items < 500 do
                local grain_s = grain_s_base * (0.8 + math.random() * 0.4)

                -- Per-grain pitch randomization via playback rate; the item
                -- extends/shrinks so the same source slice is preserved.
                local rate = 1.0
                if state.grain_pitch_rand > 0 then
                  rate = 1.0 + (math.random() - 0.5) * 2.0 * (state.grain_pitch_rand / 100.0)
                end
                local item_len = grain_s / rate
                if t + item_len > win_end then break end
                
                -- Density remapped to a safe overlap window: 0% → 15%, 100% → 75%.
                -- The 15% floor guarantees a crossfade at every grain join (no clicks).
                local overlap_s = item_len * (0.15 + density_normalized * 0.60)
                local hop_s = math.max(0.001, item_len - overlap_s)
                local fade_len = overlap_s * 0.5
                
                local max_offs = math.max(0.0, source_len - grain_s)
                local base_pos
                
                if mode == 1 then
                  read_head = read_head + (hop_s / win_dur)
                  if read_head > 1.0 then read_head = 1.0 end
                  base_pos = read_head * max_offs
                elseif mode == 2 then
                  -- Reverse: same 0→1 sweep as Forward, mapped end→start so
                  -- grains scan the source backwards across the whoosh.
                  read_head = read_head + (hop_s / win_dur)
                  if read_head > 1.0 then read_head = 1.0 end
                  base_pos = (1.0 - read_head) * max_offs
                elseif mode == 3 then
                  read_head = read_head + (hop_s / win_dur)
                  if read_head > 1.0 then read_head = 1.0 end
                  local ph = (read_head * 2.0) % 2.0
                  base_pos = (ph < 1.0 and ph or 2.0 - ph) * max_offs
                else
                  base_pos = math.random() * max_offs
                end
                base_pos = math.max(0.0, math.min(max_offs, base_pos))
                
                local ni = r.AddMediaItemToTrack(temp_track)
                r.SetMediaItemInfo_Value(ni, 'D_POSITION', t)
                r.SetMediaItemInfo_Value(ni, 'D_LENGTH', item_len)
                r.SetMediaItemInfo_Value(ni, 'B_LOOPSRC', 0)
                
                local mf = item_len * 0.49
                r.SetMediaItemInfo_Value(ni, 'D_FADEINLEN', math.min(fade_len, mf))
                r.SetMediaItemInfo_Value(ni, 'D_FADEOUTLEN', math.min(fade_len, mf))
                r.SetMediaItemInfo_Value(ni, 'D_FADEINTYPE', 2)
                r.SetMediaItemInfo_Value(ni, 'D_FADEOUTTYPE', 2)
                
                local nt = r.AddTakeToMediaItem(ni)
                r.SetMediaItemTake_Source(nt, source)
                r.SetMediaItemTakeInfo_Value(nt, 'D_STARTOFFS', base_pos)
                
                if rate ~= 1.0 then
                  r.SetMediaItemTakeInfo_Value(nt, 'D_PLAYRATE', rate)
                end

                -- Per-grain volume randomization (linear amplitude ±%)
                if state.grain_vol_rand > 0 then
                  local gv = 1.0 + (math.random() - 0.5) * 2.0 * (state.grain_vol_rand / 100.0)
                  r.SetMediaItemInfo_Value(ni, 'D_VOL', math.max(0.0, gv))
                end
                
                table.insert(layer_items, ni)
                count = count + 1
                t = t + hop_s
              end
              
              -- Glue this layer's grains into one item
              if #layer_items > 0 then
                r.SelectAllMediaItems(0, false)
                for _, li in ipairs(layer_items) do
                  r.SetMediaItemSelected(li, true)
                end
                r.Main_OnCommand(40362, 0)
                local glued = r.GetSelectedMediaItem(0, 0)
                if glued then
                  table.insert(grain_items, glued)
                end
              end
            end
          end
        end
      end
    end
  end
  
  -- Glue all layers into one final item
  if #grain_items > 0 then
    r.SelectAllMediaItems(0, false)
    for _, gi in ipairs(grain_items) do
      r.SetMediaItemSelected(gi, true)
    end
    r.Main_OnCommand(40362, 0)
  end

  -- Restore crossfade setting
  if not xfade_was_on then r.Main_OnCommand(40041, 0) end
  
  r.PreventUIRefresh(-1)
  r.Undo_EndBlock("QikWhoosh: Generate " .. unique_name, -1)
  
  state.has_generated_item = true
  state.is_generating = false
  state.is_mono = is_mono
  state.generated_start = win_start
  state.generated_end = win_end
  state.status_msg = string.format("Done — %d grains on '%s'", count, unique_name)

  r.UpdateArrange()

  if apply_env then
    r.defer(apply_volume_envelope)
  end
end

function do_resample()
  local temp_track, _ = find_temp_track()
  if not temp_track then
    state.status_msg = "Error — no temp track to resample"
    return
  end
  
  if r.CountTrackMediaItems(temp_track) == 0 then
    state.status_msg = "Error — no items on temp track"
    return
  end
  
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  local temp_item = r.GetTrackMediaItem(temp_track, 0)
  local folder_idx = r.GetMediaTrackInfo_Value(state.folder_track, 'IP_TRACKNUMBER')
  r.InsertTrackAtIndex(folder_idx, true)
  local new_track = r.GetTrack(0, folder_idx)
  
  -- Set as child track
  r.SetMediaTrackInfo_Value(new_track, 'I_FOLDERDEPTH', 0)
  
  -- Find unique resample name
  local resample_num = 1
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local _, nm = r.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
    if nm:find('Resample') then resample_num = resample_num + 1 end
  end
  r.GetSetMediaTrackInfo_String(new_track, 'P_NAME', 'Resample_' .. resample_num, true)
  
  r.MoveMediaItemToTrack(temp_item, new_track)
  r.DeleteTrack(temp_track)
  
  state.has_generated_item = false
  
  r.PreventUIRefresh(-1)
  r.Undo_EndBlock("QikWhoosh: Resample to folder", -1)
  
  r.UpdateArrange()
  state.status_msg = "Resampled to 'Resample_" .. resample_num .. "'"
end

function do_render(is_mono)
  if not state.has_generated_item then return end
  if is_mono == nil then is_mono = state.is_mono end
  state.is_mono = is_mono

  local temp_track, temp_idx = find_temp_track()
  if not temp_track then
    state.status_msg = "Temp track not found — run Preview first"
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  local prev_ts_s, prev_ts_e = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  r.GetSet_LoopTimeRange(true, false, state.generated_start, state.generated_end, false)

  -- Bounce temp track through FX to a new stem track via render-to-stem (41716)
  local track_count = r.CountTracks(0)
  r.InsertTrackAtIndex(track_count, true)
  local bounce_track = r.GetTrack(0, track_count)
  r.CreateTrackSend(temp_track, bounce_track)
  r.SetOnlyTrackSelected(bounce_track)
  r.Main_OnCommand(41716, 0)

  local send_count = r.GetTrackNumSends(temp_track, 0)
  if send_count > 0 then
    r.RemoveTrackSend(temp_track, 0, send_count - 1)
  end
  r.DeleteTrack(bounce_track)

  local stem_track = r.GetSelectedTrack(0, 0)
  if stem_track then
    r.GetSetMediaTrackInfo_String(stem_track, 'P_NAME', state.temp_track_name .. "_render", true)
    local nchan = state.is_mono and 1 or 2
    r.SetMediaTrackInfo_Value(stem_track, 'I_NCHAN', nchan)
    r.SetMediaTrackInfo_Value(temp_track, 'B_MUTE', 0)
    r.ReorderSelectedTracks(temp_idx + 1, 0)
  end

  r.GetSet_LoopTimeRange(true, false, prev_ts_s, prev_ts_e, false)

  state.status_msg = string.format("Rendered — '%s_render' placed below temp track", state.temp_track_name)

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("QikWhoosh: Render " .. state.temp_track_name, -1)
end

function do_envelope_only()
  if not validate_can_generate() then return end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  -- Find or create an empty temp track (no media items are created)
  local temp_track, _ = find_temp_track()
  if not temp_track then
    local unique_name = get_unique_temp_name()
    state.temp_track_name = unique_name
    r.InsertTrackAtIndex(0, true)
    temp_track = r.GetTrack(0, 0)
    r.GetSetMediaTrackInfo_String(temp_track, 'P_NAME', unique_name, true)
  end
  r.SetMediaTrackInfo_Value(temp_track, 'I_NCHAN', 2)

  -- Envelope bounds follow the time selection (same inset logic as Generate)
  local inset = math.max(0.0, math.min(0.30, state.inset))
  local inset_s = state.sel_duration * inset
  state.generated_start = state.sel_start + inset_s
  state.generated_end = state.sel_end - inset_s
  state.has_generated_item = true
  state.is_mono = false

  apply_volume_envelope()

  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
  r.PreventUIRefresh(-1)
  r.Undo_EndBlock("QikWhoosh: Envelope Only", -1)

  state.status_msg = string.format("Envelopes written on '%s' (no items)", state.temp_track_name)
end

function get_or_add_fx(track, search, ...)
  local track_ptr = tostring(track)
  if _fx_cache[track_ptr] and _fx_cache[track_ptr].search == search then
    local cached = _fx_cache[track_ptr]
    local _, nm = r.TrackFX_GetFXName(track, cached.idx)
    if nm:find(search, 1, true) then return cached.idx end
  end
  local cnt = r.TrackFX_GetCount(track)
  for i = 0, cnt - 1 do
    local _, nm = r.TrackFX_GetFXName(track, i)
    if nm:find(search, 1, true) then
      _fx_cache[track_ptr] = { idx = i, search = search }
      return i
    end
  end
  local add_names = {...}
  for _, name in ipairs(add_names) do
    local idx = r.TrackFX_AddByName(track, name, false, -1)
    if idx >= 0 then
      _fx_cache[track_ptr] = { idx = idx, search = search }
      return idx
    end
  end
  return -1
end

local function calc_env_bounds(sel_start, sel_end)
  local duration = sel_end - sel_start
  if duration <= 0 then return nil end

  local env_start = sel_start
  local env_end   = sel_end

  local hold_s      = duration * state.hold_time
  local peak_center = sel_start + duration * state.peak_pos
  local peak_start  = math.max(env_start, peak_center - hold_s / 2)
  local peak_end    = math.min(env_end,   peak_start  + hold_s)

  if peak_end > env_end then
    peak_end   = env_end
    peak_start = math.max(env_start, peak_end - hold_s)
  end

  local att = math.max(-1.0, math.min(1.0, state.attack))
  local rel = math.max(-1.0, math.min(1.0, state.release))

  return env_start, env_end, peak_start, peak_end, att, rel
end

local function write_doppler_env(env, v_floor, v_peak, v_floor_end, env_start, peak_start, peak_end, env_end, att, rel)
  if not env then return end
  r.DeleteEnvelopePointRange(env, env_start - 0.001, env_end + 0.001)
  
  if math.abs(peak_start - peak_end) > 0.001 then
    r.InsertEnvelopePoint(env, env_start,  v_floor,    5, -att, false, false)
    r.InsertEnvelopePoint(env, peak_start, v_peak,     0,  0.0, false, false)
    r.InsertEnvelopePoint(env, peak_end,   v_peak,     5,  rel, false, false)
    r.InsertEnvelopePoint(env, env_end,    v_floor_end, 5,  0.0, false, false)
  else
    r.InsertEnvelopePoint(env, env_start,  v_floor,    5, -att, false, false)
    r.InsertEnvelopePoint(env, peak_start, v_peak,     5,  rel, false, false)
    r.InsertEnvelopePoint(env, env_end,    v_floor_end, 5,  0.0, false, false)
  end
  r.Envelope_SortPoints(env)
end

function apply_doppler_envelopes(env_start, env_end, anchor_start, anchor_end, att, rel)
  if not state.enable_doppler then return end
  
  local temp_track, _ = find_temp_track()
  if not temp_track then return end
  if not state.has_generated_item then return end

  if not env_start then
    env_start, env_end, anchor_start, anchor_end, att, rel = calc_env_bounds(state.generated_start, state.generated_end)
    if not env_start then return end
  end

  ----------------------------------------------------------------------
  -- Helper: find an FX parameter whose name matches any pattern
  ----------------------------------------------------------------------
  local function find_fx_param(track, fx_idx, patterns)
    local count = r.TrackFX_GetNumParams(track, fx_idx)
    for i = 0, count - 1 do
      local _, name = r.TrackFX_GetParamName(track, fx_idx, i)
      if name then
        local n = name:lower()
        for _, pat in ipairs(patterns) do
          if n:find(pat, 1, true) then return i end
        end
      end
    end
    return -1
  end

  ----------------------------------------------------------------------
  -- Pitch envelope (ReaPitch — mode-controlled)
  ----------------------------------------------------------------------
  local pitch_idx = get_or_add_fx(temp_track, 'ReaPitch', 'VST: ReaPitch (Cockos)', 'VST3: ReaPitch (Cockos)')
  if pitch_idx >= 0 then
    r.TrackFX_SetEnabled(temp_track, pitch_idx, true)
    local pcount = r.TrackFX_GetNumParams(temp_track, pitch_idx)
    local pmode = state.pitch_mode
    local st = state.pitch_shift  -- -12..+12
    local p_param, centre, peak_n

    if pmode == 2 then
      -- Cents: use the cents parameter
      p_param = find_fx_param(temp_track, pitch_idx, {"cents"})
      if p_param < 0 then p_param = (pcount > 1) and 1 or 0 end
      centre = 0.5
      peak_n = (st + 100) / 200
    elseif pmode == 0 or pmode == 3 then
      -- Full Range (0) or Formant Full (3): use the semitone param at 2x range
      p_param = find_fx_param(temp_track, pitch_idx, {"pitch shift", "semitone", "pitch"})
      if p_param < 0 then p_param = (pcount > 1) and 1 or 0 end
      centre = 0.5
      peak_n = (st + 12) / 24
      -- For Formant, try to switch the algorithm mode if the param exists
      if pmode == 3 then
        local mode_param = find_fx_param(temp_track, pitch_idx, {"mode", "algorithm"})
        if mode_param >= 0 then r.TrackFX_SetParam(temp_track, pitch_idx, mode_param, 0.2) end
      end
    else
      -- Semitones (1): standard range
      p_param = find_fx_param(temp_track, pitch_idx, {"pitch shift", "semitone", "pitch"})
      if p_param < 0 then p_param = (pcount > 1) and 1 or 0 end
      centre = 0.5
      peak_n = (st + 24) / 48
    end

    local pitch_env = r.GetFXEnvelope(temp_track, pitch_idx, p_param, true)
    if pitch_env then
      local p_start = anchor_start
      local p_end = anchor_end
      write_doppler_env(pitch_env, centre, peak_n, centre, env_start, p_start, p_end, env_end, att, rel)
    end
  end

  ----------------------------------------------------------------------
  -- Filter envelope (ReaEQ — single high-pass band)
  -- Intensity sets the edge cutoff (20 Hz .. 2 kHz); the band always opens
  -- to ~20 Hz at the whoosh peak. Bypassed at intensity 0.
  -- ReaEQ exposes no automatable "type" parameter, so the band is forced
  -- via TrackFX_SetEQParam (bandtype 0 = high pass), which targets the
  -- first HP band or creates one. The envelope is written to that exact
  -- band's frequency param, located via TrackFX_GetEQParam.
  ----------------------------------------------------------------------
  local filter_idx = get_or_add_fx(temp_track, 'ReaEQ', 'VST: ReaEQ (Cockos)', 'VST3: ReaEQ (Cockos)')
  if filter_idx >= 0 then
    if state.filter_intensity <= 0.001 then
      r.TrackFX_SetEnabled(temp_track, filter_idx, false)
    else
      r.TrackFX_SetEnabled(temp_track, filter_idx, true)

      local edge_hz = filter_edge_hz(state.filter_intensity)
      local BT_HIPASS = 0  -- TrackFX_SetEQParam bandtype: 0=hipass, 5=lopass
      if r.TrackFX_SetEQParam then
        r.TrackFX_SetEQParam(temp_track, filter_idx, BT_HIPASS, 0, 0, edge_hz, false)  -- freq (Hz)
        r.TrackFX_SetEQParam(temp_track, filter_idx, BT_HIPASS, 0, 2, 0.707, false)     -- Q
        if r.TrackFX_SetEQBandEnabled then
          r.TrackFX_SetEQBandEnabled(temp_track, filter_idx, BT_HIPASS, 0, true)
        end
      end

      -- Locate the HP band's frequency param for the envelope
      local freq_param = -1
      if r.TrackFX_GetEQParam then
        for i = 0, r.TrackFX_GetNumParams(temp_track, filter_idx) - 1 do
          local ok, bt, _, pt = r.TrackFX_GetEQParam(temp_track, filter_idx, i)
          if ok and bt == BT_HIPASS and pt == 0 then freq_param = i break end
        end
      end
      if freq_param < 0 then  -- fallback for old REAPER builds
        freq_param = find_fx_param(temp_track, filter_idx, {"frequency", "freq"})
      end
      if freq_param < 0 then freq_param = 0 end

      local filter_env = r.GetFXEnvelope(temp_track, filter_idx, freq_param, true)
      if filter_env then
        local function hz_to_norm(hz)
          return math.max(0.0, math.min(1.0, math.log(hz / 20.0) / math.log(24000.0 / 20.0)))
        end
        local norm_edge = hz_to_norm(edge_hz)
        local norm_open = hz_to_norm(20.0)  -- fully open at the peak
        write_doppler_env(filter_env, norm_edge, norm_open, norm_edge, env_start, anchor_start, anchor_end, env_end, att, rel)
      end

      -- ReaEQ doesn't follow an API-written envelope until its state is
      -- re-synced (opening the FX UI does this implicitly). An offline/
      -- online cycle forces the same refresh without touching any UI.
      if r.TrackFX_SetOffline then
        r.TrackFX_SetOffline(temp_track, filter_idx, true)
        r.TrackFX_SetOffline(temp_track, filter_idx, false)
      end
    end
  end

  -- Pan envelope
  local pan_env = r.GetTrackEnvelopeByName(temp_track, 'Pan')
  if not pan_env then
    r.SetOnlyTrackSelected(temp_track)
    r.Main_OnCommand(40407, 0)
    pan_env = r.GetTrackEnvelopeByName(temp_track, 'Pan')
  end
  
  if pan_env then
    local pn_start = anchor_start
    local pn_end = anchor_end
    
    if state.is_mono then
      write_doppler_env(pan_env, 0.0, 0.0, 0.0, env_start, pn_start, pn_end, env_end, att, rel)
    else
      local str = math.abs(state.pan_value)
      local sign = (state.pan_value < 0) and 1 or -1  -- negative = L→R (sign 1), positive = R→L (sign -1)
      write_doppler_env(pan_env, -str * sign, 0.0, str * sign, env_start, pn_start, pn_end, env_end, att, rel)
    end
  end
end

function apply_volume_envelope()
  local temp_track, _ = find_temp_track()
  if not temp_track then return end
  if not state.has_generated_item then return end

  r.PreventUIRefresh(1)
  r.SetMediaTrackInfo_Value(temp_track, 'I_AUTOMODE', 1)

  local vol_env = r.GetTrackEnvelopeByName(temp_track, 'Volume')
  if not vol_env then
    r.SetOnlyTrackSelected(temp_track)
    r.Main_OnCommand(40406, 0)
    vol_env = r.GetTrackEnvelopeByName(temp_track, 'Volume')
  end
  if not vol_env then r.PreventUIRefresh(-1) return end

  local env_start, env_end, peak_start, peak_end, att, rel = calc_env_bounds(state.generated_start, state.generated_end)
  if not env_start then r.PreventUIRefresh(-1) return end

  -- Envelope point values live in the envelope's own scaling domain
  -- (REAPER defaults volume envelopes to fader scaling, where raw points
  -- are NOT plain amplitude). Convert from amplitude via the envelope's
  -- actual scaling mode. 0.0 = -inf in any domain.
  local env_scaling = r.GetEnvelopeScalingMode(vol_env)
  local env_max = r.ScaleToEnvelopeMode(env_scaling, 1.0)
  local env_min = state.min_volume_db <= -59 and 0.0
    or r.ScaleToEnvelopeMode(env_scaling, 10.0 ^ (state.min_volume_db / 20.0))

  write_doppler_env(vol_env, env_min, env_max, env_min, env_start, peak_start, peak_end, env_end, att, rel)

  apply_doppler_envelopes(env_start, env_end, peak_start, peak_end, att, rel)
  r.PreventUIRefresh(-1)
  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
end

---------------------------------------------------------------------
-- Main Draw Loop
---------------------------------------------------------------------
local started = false      -- true once the window has been drawn at least once
local hidden_frames = 0    -- consecutive frames the window reported not visible
local win_w, win_h = 640, 620  -- cached window size from previous frame

-- Fixed panel widths used in docked (single horizontal row) mode.
-- Each section keeps its natural size; the window scrolls horizontally.
local DOCK_PANEL_W = { 215, 225, 225, 290, 430 }

---------------------------------------------------------------------
-- Panel-body functions (shared by floating and docked layouts)
---------------------------------------------------------------------
local function panel_identity()
  local tb_h = 38
  local id_avail = r.ImGui_GetContentRegionAvail(ctx)
  r.ImGui_InvisibleButton(ctx, '##titleblock', id_avail, tb_h)
  local tminx, tminy = r.ImGui_GetItemRectMin(ctx)
  local tdl = r.ImGui_GetWindowDrawList(ctx)
  local sq = tb_h - 4
  local gap = 3
  local x = tminx
  for _, sz in ipairs({16, 24, sq}) do
    local iy = tminy + (tb_h - sz) * 0.5
    r.ImGui_DrawList_AddRectFilled(tdl, x, iy, x + sz, iy + sz, theme.Button, 4)
    r.ImGui_DrawList_AddRectFilled(tdl, x + 4, iy + 4, x + sz - 4, iy + sz - 4, theme.SliderGrab, 3)
    x = x + sz + gap
  end
  local tx = x + 4
  local text_w, text_h = r.ImGui_CalcTextSize(ctx, "QikWhoosh")
  r.ImGui_DrawList_AddText(tdl, tx, tminy + 8, theme.Text, "QikWhoosh")
  local bp = 4
  r.ImGui_DrawList_AddRect(tdl, tx - bp, tminy + 4, tx + text_w + bp, tminy + tb_h - 4, theme.SliderGrab, 4)
  x = tx + text_w + 8
  for _, sz in ipairs({sq, 24, 16}) do
    local iy = tminy + (tb_h - sz) * 0.5
    r.ImGui_DrawList_AddRectFilled(tdl, x, iy, x + sz, iy + sz, theme.Button, 4)
    r.ImGui_DrawList_AddRectFilled(tdl, x + 4, iy + 4, x + sz - 4, iy + sz - 4, theme.SliderGrab, 3)
    x = x + sz + gap
  end
  r.ImGui_Spacing(ctx)
  local pan_dir = math.abs(state.pan_value) < 0.06 and "—" or (state.pan_value < 0 and "L→R" or "R→L")
  local pct = math.floor((1 - 2 * state.inset) * 100)
  local status_col = 0x888899FF
  if state.status_msg and (state.status_msg:find("Error") or state.status_msg:find("Generating")) then
    status_col = 0xCC4444FF
  end
  if r.ImGui_BeginTable(ctx, "StatusGrid", 2, r.ImGui_TableFlags_SizingStretchProp()) then
    r.ImGui_TableNextRow(ctx)
    r.ImGui_TableNextColumn(ctx); r.ImGui_TextColored(ctx, status_col, string.format("Pitch: %+.0f st", state.pitch_shift))
    local filt_status = state.filter_intensity > 0.001
      and string.format("Filter: %.0f%% (%.0f Hz)", state.filter_intensity * 100, filter_edge_hz(state.filter_intensity))
      or "Filter: off"
    r.ImGui_TableNextColumn(ctx); r.ImGui_TextColored(ctx, status_col, filt_status)
    r.ImGui_TableNextRow(ctx)
    r.ImGui_TableNextColumn(ctx); r.ImGui_TextColored(ctx, status_col, string.format("Pan: %s (%d%%)", pan_dir, math.floor(math.abs(state.pan_value) * 100)))
    r.ImGui_TableNextColumn(ctx); r.ImGui_TextColored(ctx, status_col, string.format("Inset: %d%%", pct))
    r.ImGui_TableNextRow(ctx)
    r.ImGui_TableNextColumn(ctx); r.ImGui_TextColored(ctx, status_col, string.format("Duration: %.2fs", state.sel_duration))
    r.ImGui_TableNextColumn(ctx); r.ImGui_TextColored(ctx, status_col, string.format("Layers: %d", state.child_count))
    r.ImGui_EndTable(ctx)
  end
  if r.ImGui_Button(ctx, "Options", -1, 0) then show_options = not show_options end
end

local function panel_sampling()
  section_header("Sampling Mode")
  local half_w = (r.ImGui_GetContentRegionAvail(ctx) - 4) * 0.5
  if state.sampling_mode == 0 then
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x2D6D8CFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x33A07CFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x287A5EFF)
  else
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x202020FF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x333333FF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x444444FF)
  end
  if r.ImGui_Button(ctx, "Uniform", half_w, 28) then state.sampling_mode = 0 end
  show_tooltip("Grains cycle through all sources with random offsets.")
  r.ImGui_PopStyleColor(ctx, 3)
  r.ImGui_SameLine(ctx, 0, 4)
  if state.sampling_mode == 1 then
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x2D6D8CFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x33A07CFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x287A5EFF)
  else
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x202020FF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x333333FF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x444444FF)
  end
  if r.ImGui_Button(ctx, "Sequential", half_w, 28) then state.sampling_mode = 1 end
  show_tooltip("Each source plays once in order, auto-sized to fit.")
  r.ImGui_PopStyleColor(ctx, 3)

  r.ImGui_Spacing(ctx)
  section_header("Sampling Direction")
  local dir_half_w = (r.ImGui_GetContentRegionAvail(ctx) - 4) * 0.5
  for row = 0, 1 do
    for col = 0, 1 do
      local idx = row * 2 + col + 1
      if col > 0 then r.ImGui_SameLine(ctx, 0, 4) end
      if state.playback_mode == idx then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x2D6D8CFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x33A07CFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x287A5EFF)
      else
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x202020FF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x333333FF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x444444FF)
      end
      if r.ImGui_Button(ctx, PLAYBACK_MODES[idx], dir_half_w, 28) then
        state.playback_mode = idx
      end
      r.ImGui_PopStyleColor(ctx, 3)
    end
  end
  show_tooltip("Order in which sources are read: Forward, Reverse, Ping-Pong, or Random.")
end

local function panel_output()
  local can_preview = state.is_folder and state.child_count > 0 and state.sel_duration > 0 and not state.is_generating
  local can_generate = state.has_generated_item and not state.is_generating
  local can_util = state.has_generated_item
  local half_w = (r.ImGui_GetContentRegionAvail(ctx) - 4) * 0.5

  -- Title 1: Utilities + 2 buttons (mirrors Sampling Mode row)
  section_header("Utilities")
  if not can_util then r.ImGui_BeginDisabled(ctx) end
  if r.ImGui_Button(ctx, "Resample to Folder", half_w, 28) then do_resample() end
  show_tooltip("Move the glued item back into the source folder\nto enable recursive granulation.")
  r.ImGui_SameLine(ctx, 0, 4)
  if r.ImGui_Button(ctx, "Envelope Only", half_w, 28) then do_envelope_only() end
  show_tooltip("Write envelopes to the temp track without any media items.")
  if not can_util then r.ImGui_EndDisabled(ctx) end
  r.ImGui_Spacing(ctx)

  -- Title 2: Generation + 4 buttons in 2x2 (mirrors Sampling Direction grid)
  section_header("Generation")
  -- Row 1: Preview (sample grains + write envelopes to temp track)
  if not can_preview then r.ImGui_BeginDisabled(ctx) end
  if r.ImGui_Button(ctx, "Preview Stereo", half_w, 28) then do_generate(false, true) end
  show_tooltip("Generate grains + envelopes on the temp track without rendering.\nStereo preserves the source pan.\nMono sums to centre.")
  r.ImGui_SameLine(ctx, 0, 4)
  if r.ImGui_Button(ctx, "Preview Mono", half_w, 28) then do_generate(true, true) end
  show_tooltip("Same as Preview Stereo but all grains are collapsed to mono.")
  if not can_preview then r.ImGui_EndDisabled(ctx) end
  -- Row 2: Generate (bounce temp track + envelopes to a new rendered track)
  if not can_generate then r.ImGui_BeginDisabled(ctx) end
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x2D6D8CFF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x33A07CFF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x287A5EFF)
  if r.ImGui_Button(ctx, "Generate Stereo", half_w, 28) then do_render(false) end
  show_tooltip("Bounce the temp track through FX (ReaPitch, ReaEQ, ReaComp)\nto a new stem track. Stereo output.")
  r.ImGui_SameLine(ctx, 0, 4)
  if r.ImGui_Button(ctx, "Generate Mono", half_w, 28) then do_render(true) end
  show_tooltip("Same as Generate Stereo but summed to mono.")
  r.ImGui_PopStyleColor(ctx, 3)
  if not can_generate then r.ImGui_EndDisabled(ctx) end
end

local function panel_xypad()
  section_header("Grains")
  local new_density, new_size, _ = xy_pad("Grain",
    state.grain_density, 0, 100,
    state.grain_size, 10, 500,
    "%.0f%%", "%.0fms",
    "X = Grain Density (overlap).\nY = Grain Size (duration, Uniform only).\nClick and drag to adjust both.",
    "Density", "Size")
  state.grain_density = new_density
  state.grain_size = new_size
end

local function panel_visualizer()
  section_header("Woosh")
  draw_preview()
  r.ImGui_Spacing(ctx)

  if r.ImGui_BeginTable(ctx, "VolEnvLayout", 2, r.ImGui_TableFlags_SizingStretchSame()) then
    for _ = 1, 4 do
      r.ImGui_TableNextRow(ctx)
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Dummy(ctx, 1, 1)
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Dummy(ctx, 1, 1)
    end
    r.ImGui_EndTable(ctx)
  end
end

function loop()
  refresh_source_info()

  r.ImGui_SetNextWindowSize(ctx, 640, 620, r.ImGui_Cond_FirstUseEver())

  -- Push theme BEFORE Begin so Col_WindowBg applies to the window itself
  -- (ImGui reads background color at Begin time from the active stack).
  push_theme()
  -- WindowFlags_HorizontalScrollbar is always on: in floating/wide mode the
  -- stretch-table layout never overflows so no scrollbar appears; in docked
  -- mode the fixed-width panel row exceeds the docker width and the user
  -- scrolls horizontally to reveal each section.
  local win_flags = r.ImGui_WindowFlags_NoCollapse() | r.ImGui_WindowFlags_HorizontalScrollbar()
  local vis, open = r.ImGui_Begin(ctx, 'QikWhoosh v1.0.0', true, win_flags)

  if vis then
    -- Detect docked state (ReaImGui exposes IsWindowDocked). Falls back to
    -- a narrow-width heuristic for older builds that lack the binding.
    local is_docked = false
    if r.ImGui_IsWindowDocked then
      is_docked = r.ImGui_IsWindowDocked(ctx)
    else
      local cur_w = r.ImGui_GetWindowWidth(ctx)
      is_docked = cur_w < 480
    end

    if is_docked then
      -- ════════════════════════════════════════════════════════════════
      -- DOCKED: single horizontal row of fixed-width panels, side by side.
      -- Order: Identity → Sampling → Output → XY Pad → Visualizer.
      -- Each panel keeps its natural size; the window scrolls horizontally.
      -- ════════════════════════════════════════════════════════════════
      local panels = {
        { name = "Identity",   body = panel_identity   },
        { name = "Sampling",   body = panel_sampling   },
        { name = "Output",     body = panel_output     },
        { name = "XYPad",      body = panel_xypad      },
        { name = "Visualizer", body = panel_visualizer },
      }
      -- Capture full content height once so every panel is equally tall.
      local _, panel_h = r.ImGui_GetContentRegionAvail(ctx)
      for i, p in ipairs(panels) do
        if i > 1 then r.ImGui_SameLine(ctx) end
        if r.ImGui_BeginChild(ctx, '##dock_' .. p.name, DOCK_PANEL_W[i], panel_h, 1) then
          p.body()
          r.ImGui_EndChild(ctx)
        end
      end
    else
      -- ════════════════════════════════════════════════════════════════
      -- FLOATING: existing 2-row layout
      --   TOP ROW: 3 columns — (Identity/Status) (Sampling) (Output)
      --   BOTTOM ROW: 2 columns — (XY Pad) (Visualizer)
      -- ════════════════════════════════════════════════════════════════
      local table_flags = r.ImGui_TableFlags_SizingStretchProp()

      if r.ImGui_BeginTable(ctx, "TopRow", 3, table_flags) then
        r.ImGui_TableSetupColumn(ctx, "Identity", r.ImGui_TableColumnFlags_WidthStretch(), 1.2)
        r.ImGui_TableSetupColumn(ctx, "Sampling", r.ImGui_TableColumnFlags_WidthStretch(), 1.0)
        r.ImGui_TableSetupColumn(ctx, "Output",  r.ImGui_TableColumnFlags_WidthStretch(), 1.0)
        r.ImGui_TableNextRow(ctx)

        r.ImGui_TableNextColumn(ctx); panel_identity()
        r.ImGui_TableNextColumn(ctx); panel_sampling()
        r.ImGui_TableNextColumn(ctx); panel_output()

        r.ImGui_EndTable(ctx)
      end

      r.ImGui_Spacing(ctx)
      r.ImGui_Separator(ctx)
      r.ImGui_Spacing(ctx)

      if r.ImGui_BeginTable(ctx, "BottomRow", 2, table_flags) then
        r.ImGui_TableSetupColumn(ctx, "XYPad",      r.ImGui_TableColumnFlags_WidthStretch(), 1.0)
        r.ImGui_TableSetupColumn(ctx, "Visualizer", r.ImGui_TableColumnFlags_WidthStretch(), 2.6)
        r.ImGui_TableNextRow(ctx)

        r.ImGui_TableNextColumn(ctx); panel_xypad()
        r.ImGui_TableNextColumn(ctx); panel_visualizer()

        r.ImGui_EndTable(ctx)
      end
    end

    -- Cache window size for next frame
    win_w, win_h = r.ImGui_GetWindowSize(ctx)

    r.ImGui_End(ctx)
  end

  -- Pop the main window's theme AFTER End so it covered Begin→End.
  pop_theme()

  if show_options then
    push_theme()
    -- NoDocking keeps the Options popup floating (guard for older ReaImGui builds)
    local opt_flags = r.ImGui_WindowFlags_AlwaysAutoResize()
    if r.ImGui_WindowFlags_NoDocking then
      opt_flags = opt_flags | r.ImGui_WindowFlags_NoDocking()
    end
    local opt_vis, opt_open = r.ImGui_Begin(ctx, "QikWhoosh Options##opts", true, opt_flags)
    if opt_vis then
      local pitch_avail = r.ImGui_GetContentRegionAvail(ctx)
      local pitch_bw = (pitch_avail - 12) * 0.25
      if pitch_bw < 80 then pitch_bw = 80 end
      r.ImGui_Text(ctx, "Pitch Mode")
      local pitch_labels = {"Shift Full", "Shift Semi", "Shift Cents", "Formant Full"}
      for i, label in ipairs(pitch_labels) do
        if i > 1 then r.ImGui_SameLine(ctx, 0, 4) end
        if state.pitch_mode == i - 1 then
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x2D6D8CFF)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x33A07CFF)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x287A5EFF)
        else
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x202020FF)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x333333FF)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x444444FF)
        end
        if r.ImGui_Button(ctx, label, pitch_bw, 28) then state.pitch_mode = i - 1 end
        r.ImGui_PopStyleColor(ctx, 3)
      end

      r.ImGui_Spacing(ctx)
      r.ImGui_Text(ctx, "Min Volume Floor")
      local min_db = state.min_volume_db
      local changed, new_db = r.ImGui_SliderDouble(ctx, "##minvol", min_db, -60.0, -20.0, "%.0f dB")
      if changed then state.min_volume_db = new_db end
      if r.ImGui_IsItemHovered(ctx) then
        r.ImGui_BeginTooltip(ctx)
        r.ImGui_PushTextWrapPos(ctx, r.ImGui_GetFontSize(ctx) * 35.0)
        local tip = string.format("Volume envelope floor: %.0f dB below peak.\nLower values = more silence at envelope edges.\n-60 ≈ silent.", new_db or min_db)
        r.ImGui_Text(ctx, tip)
        r.ImGui_PopTextWrapPos(ctx)
        r.ImGui_EndTooltip(ctx)
      end
      r.ImGui_Spacing(ctx)
      r.ImGui_Text(ctx, "Grain Randomization")
      state.grain_pitch_rand = labeled_slider("Pitch", state.grain_pitch_rand, 0.0, 20.0, "±%.1f%%", 0.0,
        "Random playback-rate variation per grain (Uniform mode).\nGrains extend/shrink to preserve the source slice.\n0% = off. Double-click resets.")
      state.grain_vol_rand = labeled_slider("Volume", state.grain_vol_rand, 0.0, 15.0, "±%.1f%%", 0.0,
        "Random volume variation per grain (Uniform mode).\n0% = off. Double-click resets.")
      r.ImGui_End(ctx)
    end
    pop_theme()
    if not opt_open then show_options = false end
  end

  -- Track real window visibility. `open` only flips false on the floating
  -- close (X) button; a docked window whose tab is dismissed (or any hidden
  -- state) surfaces as vis==false from Begin. We must not call End when
  -- vis==false, and we use the same signal to detect actual window loss.
  if vis then
    started = true
    hidden_frames = 0
  else
    hidden_frames = hidden_frames + 1
  end

  -- Terminate the defer chain once the window is genuinely gone: either the
  -- user clicked the close button (open==false) or the window has stayed
  -- hidden for a brief grace period (docked tab dismissed / window hidden).
  -- The grace absorbs one-frame invisibility during dock transitions.
  local closed = (not open) or (started and hidden_frames > 15)

  if closed then
    -- ReaImGui reclaims the context when the script ends; destroy it
    -- explicitly on the next tick if the API is available.
    if r.ImGui_DestroyContext then
      r.defer(function() r.ImGui_DestroyContext(ctx) end)
    end
    return
  end

  r.defer(loop)
end

r.atexit(save_settings)
load_settings()
r.defer(loop)
