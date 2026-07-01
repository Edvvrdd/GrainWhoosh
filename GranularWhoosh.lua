-- @description GranularWhoosh
-- @author Ed
-- @version 1.0
-- @provides [main] .
-- @about
--   # GranularWhoosh — Granular Whoosh Generator
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
--   - Major rebuild of the GranularWhoosh tool
--   - Improved UI and performance
--   - Added new features and enhancements
--   v0.9.1
--   - Fixed docking crash: ImGui_End() now only called when window is visible
--   - Added docking configuration support
--   v0.9.0
--   - Initial beta release

local r = reaper

-- Check for ReaImGui
if not r.ImGui_CreateContext then
  r.ShowMessageBox("This script requires ReaImGui.", "ReaImGui not found", 0)
  return
end

-- Initialize ReaImGui context
local ctx = r.ImGui_CreateContext("GranularWhoosh")

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
  ButtonActive    = 0x2D8C6DFF,
  SliderGrab      = 0x2D8C6DFF,
  CheckMark       = 0x2D8C6DFF,
  Header          = 0x202020FF,
  HeaderHovered   = 0x2D8C6DFF,
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

-- Constants
local PLAYBACK_MODES = {"Forward", "Reverse", "Ping-Pong", "Random"}
local SAMPLING_MODES = {"Uniform", "Sequential"}
-- (direction constants removed — pan and pitch are now single signed sliders)

-- Seed Lua's PRNG with high-resolution entropy (wallclock + REAPER's
-- precise timer). Default Lua starts with a fixed seed, so without this
-- every script run / preview / render would produce identical grains.
-- Call this before any math.random() usage that should differ each time.
local function seed_random()
  math.randomseed(os.time() + math.floor((r.time_precise() % 1) * 1000000))
  math.random()  -- discard first value (poorly distributed in many Lua builds)
end

local grain_vis_data = {}

local function regen_grain_vis_data()
  grain_vis_data = {}
  for i = 1, 200 do
    local xf = math.random()
    table.insert(grain_vis_data, {
      x_frac = xf,
      h_frac = 0.2 + math.random() * 0.8,
      phase_offs = math.random() * 6.28,
      edge = xf < 0.15 or xf > 0.85,
    })
  end
end

seed_random()           -- fresh visualization dots each script run
regen_grain_vis_data()

-- Initial State
local state = {
  -- Source / Sampling
  sampling_mode = 0, -- 0 = Uniform, 1 = Sequential
  grain_size = 80.0,   -- Uniform: 10-500ms grain length
  grain_density = 60.0,   -- 0-100 percentage (maps to density/crossfade)
  randomness = 0.0,
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
  filter_base_freq = 200.0,
  filter_peak_freq = 15000.0,
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

-- Caches
local _track_cache = { track = nil, time = 0 }
local _fx_cache = {}
local DRAW_SEGMENTS = 24

---------------------------------------------------------------------
-- UI Helper Functions
---------------------------------------------------------------------
function xy_pad(label, val_x, min_x, max_x, val_y, min_y, max_y, fmt_x, fmt_y, tooltip, label_x, label_y)
  local avail = r.ImGui_GetContentRegionAvail(ctx)
  local label_margin = 18  -- space for axis labels
  local pad = math.min(avail - label_margin - 4, 235)
  if pad < 80 then pad = 80 end
  local H = pad
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
  r.ImGui_DrawList_AddLine(dl, cx, hy, cx + pad, hy, 0x442D8C6D, 1.0)
  r.ImGui_DrawList_AddLine(dl, hx, cy, hx, cy + H, 0x442D8C6D, 1.0)

  -- Handle (glow + dot)
  r.ImGui_DrawList_AddCircleFilled(dl, hx, hy, 8, 0x332D8C6D)
  r.ImGui_DrawList_AddCircleFilled(dl, hx, hy, 5, 0xCC2D8C6D)
  r.ImGui_DrawList_AddCircleFilled(dl, hx, hy, 2, 0xFFFFFFFF)

  -- Value readout (small, in corners)
  r.ImGui_DrawList_AddText(dl, cx + 4, cy + H - 14, 0xFF888899,
    string.format(fmt_x, val_x))
  r.ImGui_DrawList_AddText(dl, cx + pad - 40, cy + 2, 0xFF888899,
    string.format(fmt_y, val_y))

  -- ── AXIS LABELS ──
  -- X axis label ("Density") centered below the pad
  if label_x then
    local txt_w = r.ImGui_CalcTextSize(ctx, label_x)
    r.ImGui_DrawList_AddText(dl, cx + (pad - txt_w) * 0.5, cy + H + 3, theme.TextDisabled, label_x)
  end

  -- Y axis label ("Size") drawn vertically along the left side
  if label_y then
    local chars = {}
    for c in label_y:gmatch(".") do chars[#chars+1] = c end
    local char_h = r.ImGui_GetTextLineHeight(ctx)
    local total_h = #chars * char_h
    local start_y = cy + (H - total_h) * 0.5
    for i, c in ipairs(chars) do
      r.ImGui_DrawList_AddText(dl, cx - label_margin + 2, start_y + (i - 1) * char_h, theme.TextDisabled, c)
    end
  end

  if tooltip and (hovered or active) then
    show_tooltip(tooltip)
  end

  -- Reserve space below for the X axis label
  r.ImGui_Dummy(ctx, 1, 16)

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

local preview_frame = 0
local peak_dragging = false  -- tracks whether the peak position dot is being dragged
local peak_drag_start_my = 0  -- mouse Y at drag start
local peak_drag_start_hold = 0  -- hold_time at drag start
local rise_dragging = false  -- tracks whether the rise tension triangle is being dragged
local fall_dragging = false  -- tracks whether the fall tension triangle is being dragged
local filter_top_dragging = false    -- filter peak knob (top)
local filter_bottom_dragging = false -- filter base knob (bottom)

function draw_preview(width_offset)
  preview_frame = preview_frame + 1

  local dl = r.ImGui_GetWindowDrawList(ctx)
  local W = r.ImGui_GetContentRegionAvail(ctx) - (width_offset or 0)
  local H = 160

  -- InvisibleButton captures mouse events so the window isn't dragged
  -- when interacting with the visualizer. All drawing happens via the
  -- DrawList using the button's screen position.
  r.ImGui_InvisibleButton(ctx, '##preview', W, H)
  local cx, cy = r.ImGui_GetItemRectMin(ctx)

  -- Pure black background
  r.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + W, cy + H, 0x000000FF, 4)
  r.ImGui_DrawList_AddRect(dl, cx, cy, cx + W, cy + H, theme.Border, 4)

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

  -- ── GRAIN DOTS ──
  -- Dots whose vertical spread follows the volume envelope.
  -- At env=0 (edges) dots cluster at the horizontal middle.
  -- At env=1 (peak) dots expand to fill top and bottom.
  r.ImGui_DrawList_PushClipRect(dl, cx, cy, cx + W, cy + H, true)
  local density_norm = state.grain_density / 100
  local num_grains = math.floor(30 + (170 * density_norm))
  local rx = 7.5 + ((state.grain_size - 10) / 490) * 67.5
  local ry = 7.5
  local cy_mid = cy + H * 0.5
  local vspread = H * 0.5 - ry  -- max vertical offset so dots touch edges exactly

  local base_r, base_g, base_b = 0x44, 0x88, 0xCC
  local dot_col = (base_r << 24) | (base_g << 16) | (base_b << 8) | 0xCC
  local pan_mag = math.abs(state.pan_value)
  local shift_col = dot_col
  if pan_mag > 0.06 then
    local t = (pan_mag - 0.06) / 0.94
    local r = math.floor(base_r + (0x88 - base_r) * t)
    local g = math.floor(base_g + (0x33 - base_g) * t)
    local b = math.floor(base_b + (0x44 - base_b) * t)
    shift_col = (r << 24) | (g << 16) | (b << 8) | 0xCC
  end
  for i = 1, num_grains do
    local g = grain_vis_data[i]
    local x = cx + margin_w + (g.x_frac * active_w)
    if x - rx >= cx and x + rx <= cx + W then
      local env = math.max(0, math.min(1, vol_fn(g.x_frac)))
      local y = cy_mid + (g.h_frac - 0.5) * 2.0 * vspread * env
      if y - ry >= cy and y + ry <= cy + H then
        local phase = (preview_frame * 0.05 + g.phase_offs) % 6.28
        local fade = 0.1 + 0.9 * (0.5 + 0.5 * math.sin(phase))
        local dr, ddy = rx * fade, ry * fade
        local col = g.edge and pan_mag > 0.06 and shift_col or dot_col
        r.ImGui_DrawList_AddEllipseFilled(dl, x, y, dr, ddy, col)
        r.ImGui_DrawList_AddEllipse(dl, x, y, dr, ddy, col, 0, 0, 1.0)
      end
    end
  end
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

  -- ── FILTER HORIZONTAL LINES (base = green, peak = bright green) ──
  -- Each line hides independently when its knob is at the extreme of the
  -- slider travel (mirrors pitch envelope behavior).
  local function hz_to_norm(hz)
    return math.max(0.0, math.min(1.0, math.log(hz / 20.0) / math.log(24000.0 / 20.0)))
  end
  local filter_base_y = cy + H - hz_to_norm(state.filter_base_freq) * (H - 8) - 4
  local filter_peak_y = cy + H - hz_to_norm(state.filter_peak_freq) * (H - 8) - 4
  if state.filter_peak_freq < 20000.0 then
    r.ImGui_DrawList_AddLine(dl, cx, filter_peak_y, cx + W, filter_peak_y, 0xCC2D8C6D, 1.5)
  end
  if state.filter_base_freq > 20.0 then
    r.ImGui_DrawList_AddLine(dl, cx, filter_base_y, cx + W, filter_base_y, 0x662D8C6D, 1.0)
  end

  -- (Spill lines are drawn after the peak dot — they need its position)

  -- ── PEAK POSITION DOT (draggable: X = peak pos, Y = hold time) ──
  local peak_dot_x = cx + state.peak_pos * W
  local peak_dot_y = cy + H * 0.5
  local peak_dot_ry = 8
  local peak_dot_rx = 8 + state.hold_time * 80  -- width grows with hold time (0..0.5 → 8..48)
  local mx, my = r.ImGui_GetMousePos(ctx)
  local mouse_down = r.ImGui_IsMouseDown(ctx, 0)
  local mouse_clicked = r.ImGui_IsMouseClicked(ctx, 0)
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
  r.ImGui_DrawList_AddEllipseFilled(dl, peak_dot_x, peak_dot_y, peak_dot_rx + 4, peak_dot_ry + 4, 0x332D8C6D)  -- outer glow
  r.ImGui_DrawList_AddEllipseFilled(dl, peak_dot_x, peak_dot_y, peak_dot_rx,     peak_dot_ry,     0xFF2D8C6D)  -- body
  r.ImGui_DrawList_AddEllipseFilled(dl, peak_dot_x, peak_dot_y, peak_dot_rx - 4, peak_dot_ry - 4, 0xFF33A07C)  -- highlight

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
  local rise_region_w = (peak_dot_x - peak_dot_rx) - gap - cx
  -- Position: attack=-1.0 → far left, attack=1.0 → near peak (right)
  local rise_tri_x = cx + ((1.0 - state.attack) / 2.0) * rise_region_w
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
    local new_t = (mx - cx) / rise_region_w
    new_t = math.max(0, math.min(1, new_t))
    -- new_t=0 (left) → 1.0 (sharp), new_t=1 (right, near peak) → -1.0 (relaxed)
    state.attack = 1.0 - (new_t * 2.0)
    rise_tri_x = cx + ((1.0 - state.attack) / 2.0) * rise_region_w
  end

  -- Draw the < triangle (gold, glowy)
  local p1x, p1y = rise_tri_x - rise_tri_s, rise_tri_y           -- left point
  local p2x, p2y = rise_tri_x + rise_tri_s, rise_tri_y - rise_tri_s  -- top right
  local p3x, p3y = rise_tri_x + rise_tri_s, rise_tri_y + rise_tri_s  -- bottom right
  r.ImGui_DrawList_AddTriangleFilled(dl, p1x, p1y, p2x, p2y, p3x, p3y, 0x332D8C6D)  -- glow (bigger)
  local gs = rise_tri_s + 3
  r.ImGui_DrawList_AddTriangleFilled(dl, rise_tri_x - gs, rise_tri_y, rise_tri_x + gs, rise_tri_y - gs, rise_tri_x + gs, rise_tri_y + gs, 0x332D8C6D)
  r.ImGui_DrawList_AddTriangleFilled(dl, p1x, p1y, p2x, p2y, p3x, p3y, 0xFF2D8C6D)  -- body
  r.ImGui_DrawList_AddTriangleFilled(dl, rise_tri_x - rise_tri_s + 3, rise_tri_y, rise_tri_x + rise_tri_s - 3, rise_tri_y - rise_tri_s + 4, rise_tri_x + rise_tri_s - 3, rise_tri_y + rise_tri_s - 4, 0xFF33A07C)  -- highlight

  -- ── FALL TENSION TRIANGLE (draggable, horizontal only) ──
  -- Sits in the fall region (peak dot to right edge). > points right.
  -- Near peak (left) = sharp (1.0), far from peak (right) = relaxed (-1.0).
  local fall_region_start = peak_dot_x + peak_dot_rx + gap
  local fall_region_w = (cx + W) - fall_region_start
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
  r.ImGui_DrawList_AddTriangleFilled(dl, fall_tri_x + fgs, fall_tri_y, fall_tri_x - fgs, fall_tri_y - fgs, fall_tri_x - fgs, fall_tri_y + fgs, 0x332D8C6D)
  r.ImGui_DrawList_AddTriangleFilled(dl, fp1x, fp1y, fp2x, fp2y, fp3x, fp3y, 0xFF2D8C6D)  -- body
  r.ImGui_DrawList_AddTriangleFilled(dl, fall_tri_x + fall_tri_s - 3, fall_tri_y, fall_tri_x - fall_tri_s + 3, fall_tri_y - fall_tri_s + 4, fall_tri_x - fall_tri_s + 3, fall_tri_y + fall_tri_s - 4, 0xFF33A07C)  -- highlight

  -- ── HOVER READOUT ──
  if not peak_dragging and not rise_dragging and not fall_dragging and mx >= cx and mx <= cx + W and my >= cy and my <= cy + H then
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
local SETTINGS_SECTION = "GranularWhoosh"

function save_settings()
  local data = {
    sampling_mode = state.sampling_mode,
    grain_size = state.grain_size,
    grain_density = state.grain_density,
    randomness = state.randomness,
    playback_mode = state.playback_mode,
    inset = state.inset,
    peak_pos = state.peak_pos,
    hold_time = state.hold_time,
    attack = state.attack,
    release = state.release,
    pitch_shift = state.pitch_shift,
    filter_base_freq = state.filter_base_freq,
    filter_peak_freq = state.filter_peak_freq,
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
  
  -- Remove existing temp track
  local existing_track, _ = find_temp_track()
  if existing_track then
    r.DeleteTrack(existing_track)
  end
  
  -- Get unique name
  local unique_name = get_unique_temp_name()
  state.temp_track_name = unique_name
  
  -- Create temp track at index 0 (top of project)
  r.InsertTrackAtIndex(0, true)
  local temp_track = r.GetTrack(0, 0)
  r.GetSetMediaTrackInfo_String(temp_track, 'P_NAME', unique_name, true)
  
  -- Set channel count (1=mono, 2=stereo)
  r.SetMediaTrackInfo_Value(temp_track, 'I_NCHAN', is_mono and 1 or 2)
  
  -- Force auto-crossfade on
  local xfade_was_on = r.GetToggleCommandState(40041) == 1
  if not xfade_was_on then r.Main_OnCommand(40041, 0) end
  
  -- Get time selection with edge compression
  local inset = math.max(0.0, math.min(0.30, state.inset))
  local inset_s = state.sel_duration * inset
  local win_start = state.sel_start + inset_s
  local win_end = state.sel_end - inset_s
  local win_dur = math.max(0.001, win_end - win_start)
  
  -- Use cached source tracks (populated by refresh_source_info)
  local source_tracks = state.source_tracks
  
  local grain_items = {}
  local count = 0
  
  -- Calculate actual values from unified sliders
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
      if t + item_len > win_end then break end
      
      local track = source_tracks[order[i]]
      if not track then break end
      
      local item = r.GetTrackMediaItem(track, 0)
      if item then
        local take = r.GetActiveTake(item)
        if take then
          local source = r.GetMediaItemTake_Source(take)
          if source then
            local new_item = r.AddMediaItemToTrack(temp_track)
            r.SetMediaItemInfo_Value(new_item, 'D_POSITION', t)
            r.SetMediaItemInfo_Value(new_item, 'D_LENGTH', item_len)
            r.SetMediaItemInfo_Value(new_item, 'B_LOOPSRC', 0)
            
            local max_fade = item_len * 0.49
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
    
  else -- Uniform
    local grain_s_base = state.grain_size / 1000.0
    local t = win_start
    local mode = state.playback_mode
    
    -- Build source cycling order
    local num_sources = #source_tracks
    local source_order = {}
    for i = 1, num_sources do source_order[i] = i end
    
    local source_idx = 1
    local read_head = 0.0 -- 0.0 to 1.0 position in source
    
    while t < win_end and count < 2000 do
      local track = source_tracks[source_order[source_idx]]
      local item = r.GetTrackMediaItem(track, 0)
      
      if item then
        local take = r.GetActiveTake(item)
        if take then
          local source = r.GetMediaItemTake_Source(take)
          if source then
            local grain_s = grain_s_base * (0.8 + math.random() * 0.4)
            
            if t + grain_s > win_end then break end
            
            local hop_s = grain_s * (1.0 - density_normalized * 0.75)
            hop_s = math.max(hop_s, 0.001)
            
            local overlap_s = math.max(0.0, grain_s - hop_s)
            local fade_len = overlap_s * 0.5
            
            -- Calculate read-head position based on playback mode
            local source_len = r.GetMediaSourceLength(source)
            local max_offs = math.max(0.0, source_len - grain_s)
            local base_pos
            
            if mode == 1 then
              -- Forward: sweep from start to end
              read_head = read_head + (hop_s / win_dur)
              if read_head > 1.0 then read_head = 1.0 end
              base_pos = read_head * max_offs
            elseif mode == 2 then
              -- Reverse: sweep from end to start
              read_head = read_head - (hop_s / win_dur)
              if read_head < 0.0 then read_head = 0.0 end
              base_pos = (1.0 - read_head) * max_offs
            elseif mode == 3 then
              -- Ping-Pong: bounce back and forth
              read_head = read_head + (hop_s / win_dur)
              if read_head > 1.0 then read_head = 1.0 end
              local ph = (read_head * 2.0) % 2.0
              local sweep = ph < 1.0 and ph or 2.0 - ph
              base_pos = sweep * max_offs
            else
              -- Random: random position
              base_pos = math.random() * max_offs
            end
            base_pos = math.max(0.0, math.min(max_offs, base_pos))
            
            local new_item = r.AddMediaItemToTrack(temp_track)
            r.SetMediaItemInfo_Value(new_item, 'D_POSITION', t)
            r.SetMediaItemInfo_Value(new_item, 'D_LENGTH', grain_s)
            r.SetMediaItemInfo_Value(new_item, 'B_LOOPSRC', 0)
            
            local max_fade = grain_s * 0.49
            r.SetMediaItemInfo_Value(new_item, 'D_FADEINLEN', math.min(fade_len, max_fade))
            r.SetMediaItemInfo_Value(new_item, 'D_FADEOUTLEN', math.min(fade_len, max_fade))
            r.SetMediaItemInfo_Value(new_item, 'D_FADEINTYPE', 1)
            r.SetMediaItemInfo_Value(new_item, 'D_FADEOUTTYPE', 1)
            
            local new_take = r.AddTakeToMediaItem(new_item)
            r.SetMediaItemTake_Source(new_take, source)
            r.SetMediaItemTakeInfo_Value(new_take, 'D_STARTOFFS', base_pos)
            
            if state.randomness > 0 then
              local rnd_st = (math.random() - 0.5) * 2.0 * state.randomness * 12
              local rate = 2.0 ^ (rnd_st / 12.0)
              r.SetMediaItemTakeInfo_Value(new_take, 'D_PLAYRATE', rate)
            end
            
            table.insert(grain_items, new_item)
            count = count + 1
            
            -- Cycle to next source
            source_idx = source_idx + 1
            if source_idx > num_sources then
              source_idx = 1
            end
            
            t = t + hop_s
          else
            t = t + 0.01
          end
        else
          t = t + 0.01
        end
      else
        t = t + 0.01
      end
    end
  end
  
  -- Extend last grain to exactly match time selection end
  if #grain_items > 0 then
    local last_item = grain_items[#grain_items]
    local last_pos = r.GetMediaItemInfo_Value(last_item, 'D_POSITION')
    local remaining = win_end - last_pos
    if remaining > 0 then
      r.SetMediaItemInfo_Value(last_item, 'D_LENGTH', remaining)
      local max_fade = remaining * 0.49
      r.SetMediaItemInfo_Value(last_item, 'D_FADEOUTLEN', max_fade)
    end
  end
  
  -- Glue items
  if #grain_items > 0 then
    r.SelectAllMediaItems(0, false)
    for _, item in ipairs(grain_items) do
      r.SetMediaItemSelected(item, true)
    end
    r.Main_OnCommand(40362, 0) -- Glue items
  end
  
  -- Restore crossfade setting
  if not xfade_was_on then r.Main_OnCommand(40041, 0) end
  
  r.PreventUIRefresh(-1)
  r.Undo_EndBlock("GranularWhoosh: Generate " .. unique_name, -1)
  
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
  
  -- Get the glued item
  local temp_item = r.GetTrackMediaItem(temp_track, 0)
  
  -- Find folder index
  local folder_idx = r.GetMediaTrackInfo_Value(state.folder_track, 'IP_TRACKNUMBER')
  
  -- Create new track under folder
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
  
  -- Move item to new track
  r.MoveMediaItemToTrack(temp_item, new_track)
  
  -- Delete temp track
  r.DeleteTrack(temp_track)
  
  state.has_generated_item = false
  
  r.PreventUIRefresh(-1)
  r.Undo_EndBlock("GranularWhoosh: Resample to folder", -1)
  
  r.UpdateArrange()
  state.status_msg = "Resampled to 'Resample_" .. resample_num .. "'"
end

function do_render(is_mono)
  if not state.has_generated_item then return end
  if is_mono == nil then is_mono = state.is_mono end
  state.is_mono = is_mono

  -- Find temp track
  local temp_track, temp_idx = find_temp_track()
  if not temp_track then
    state.status_msg = "Temp track not found — run Preview first"
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  -- Set time selection to generated range
  local prev_ts_s, prev_ts_e = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  r.GetSet_LoopTimeRange(true, false, state.generated_start, state.generated_end, false)

  -- Create bounce track at the end
  local track_count = r.CountTracks(0)
  r.InsertTrackAtIndex(track_count, true)
  local bounce_track = r.GetTrack(0, track_count)

  -- Create send from temp track to bounce track
  r.CreateTrackSend(temp_track, bounce_track)

  -- Select only bounce track, run render action
  r.SetOnlyTrackSelected(bounce_track)

  -- 41716 = Track: Render selected area of tracks to stereo post-fader stem tracks
  r.Main_OnCommand(41716, 0)

  -- Remove the send from temp_track
  local send_count = r.GetTrackNumSends(temp_track, 0)
  if send_count > 0 then
    r.RemoveTrackSend(temp_track, 0, send_count - 1)
  end

  -- Delete the bounce track
  r.DeleteTrack(bounce_track)

  -- The render action leaves a new stem track selected
  local stem_track = r.GetSelectedTrack(0, 0)
  if stem_track then
    r.GetSetMediaTrackInfo_String(stem_track, 'P_NAME', state.temp_track_name .. "_render", true)
    local nchan = state.is_mono and 1 or 2
    r.SetMediaTrackInfo_Value(stem_track, 'I_NCHAN', nchan)
    r.SetMediaTrackInfo_Value(temp_track, 'B_MUTE', 0)

    -- Move stem track right below temp track
    r.ReorderSelectedTracks(temp_idx + 1, 0)
  end

  -- Restore time selection
  r.GetSet_LoopTimeRange(true, false, prev_ts_s, prev_ts_e, false)

  state.status_msg = string.format("Rendered — '%s_render' placed below temp track", state.temp_track_name)

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("GranularWhoosh: Render " .. state.temp_track_name, -1)
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
  r.Undo_EndBlock("GranularWhoosh: Envelope Only", -1)

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
    r.InsertEnvelopePoint(env, env_start,  v_floor,    5,  att, false, false)
    r.InsertEnvelopePoint(env, peak_start, v_peak,     0,  0.0, false, false)
    r.InsertEnvelopePoint(env, peak_end,   v_peak,     5, -rel, false, false)
    r.InsertEnvelopePoint(env, env_end,    v_floor_end, 5,  0.0, false, false)
  else
    r.InsertEnvelopePoint(env, env_start,  v_floor,    5,  att, false, false)
    r.InsertEnvelopePoint(env, peak_start, v_peak,     5, -rel, false, false)
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

  -- Pitch envelope
  local pitch_idx = get_or_add_fx(temp_track, 'ReaPitch', 'VST: ReaPitch (Cockos)', 'VST3: ReaPitch (Cockos)')
  if pitch_idx >= 0 then
    r.TrackFX_SetEnabled(temp_track, pitch_idx, true)
    local pitch_env = r.GetFXEnvelope(temp_track, pitch_idx, 0, true)
    if pitch_env then
      local st = state.pitch_shift  -- -12..+12
      local centre = 24 / 48  -- 0 semitones in normalized form
      local peak_n = (st + 24) / 48  -- signed shift at the peak

      local p_start = anchor_start
      local p_end = anchor_end

      write_doppler_env(pitch_env, centre, peak_n, centre, env_start, p_start, p_end, env_end, att, rel)
    end
  end

  -- Filter envelope (ReaEQ lowpass)
  -- Auto-disable: when both filter knobs sit at their maxima (peak at
  -- 20000 and base pushed up against peak) there is no audible sweep,
  -- so the EQ doppler is bypassed: ReaEQ is disabled and no envelope is
  -- written. The condition mirrors the preview's filter_doppler_off.
  local filter_doppler_off =
    state.filter_peak_freq >= 20000.0 and
    state.filter_base_freq >= state.filter_peak_freq - 100.5
  local filter_idx = get_or_add_fx(temp_track, 'ReaEQ', 'VST: ReaEQ (Cockos)', 'VST3: ReaEQ (Cockos)')
  if filter_idx >= 0 then
    if filter_doppler_off then
      r.TrackFX_SetEnabled(temp_track, filter_idx, false)
    else
      r.TrackFX_SetEnabled(temp_track, filter_idx, true)
      r.TrackFX_SetParam(temp_track, filter_idx, 12, 0.0)
      r.TrackFX_SetParam(temp_track, filter_idx, 11, 1.0)
      r.TrackFX_SetParam(temp_track, filter_idx, 15, 0.7)

      local filter_env = r.GetFXEnvelope(temp_track, filter_idx, 14, true)
      if filter_env then
        local function hz_to_norm(hz)
          return math.max(0.0, math.min(1.0, math.log(hz / 20.0) / math.log(24000.0 / 20.0)))
        end

        local norm_base = hz_to_norm(state.filter_base_freq)
        local norm_peak = hz_to_norm(state.filter_peak_freq)

        local f_start = anchor_start
        local f_end = anchor_end

        write_doppler_env(filter_env, norm_base, norm_peak, norm_base, env_start, f_start, f_end, env_end, att, rel)
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

  local env_min = r.ScaleToEnvelopeMode(1, 0.0)
  local env_max = r.ScaleToEnvelopeMode(1, 1.0)

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
  local tb_h = 30
  local id_avail = r.ImGui_GetContentRegionAvail(ctx)
  r.ImGui_InvisibleButton(ctx, '##titleblock', id_avail, tb_h)
  local tminx, tminy = r.ImGui_GetItemRectMin(ctx)
  local tdl = r.ImGui_GetWindowDrawList(ctx)
  local sq = tb_h - 4
  r.ImGui_DrawList_AddRectFilled(tdl, tminx, tminy, tminx + sq, tminy + sq, theme.Button, 4)
  r.ImGui_DrawList_AddRectFilled(tdl, tminx + 6, tminy + 6, tminx + sq - 6, tminy + sq - 6, theme.SliderGrab, 3)
  r.ImGui_DrawList_AddText(tdl, tminx + sq + 8, tminy + 5, theme.Text, "GranularWhoosh")
  r.ImGui_DrawList_AddText(tdl, tminx + sq + 8, tminy + 19, theme.TextDisabled,
    string.format("%.2fs  ·  %d track%s", state.sel_duration, state.child_count, state.child_count == 1 and "" or "s"))
  r.ImGui_Spacing(ctx)
  r.ImGui_Text(ctx, "Track Name")
  r.ImGui_SetNextItemWidth(ctx, -1)
  local _, new_name = r.ImGui_InputText(ctx, '##tempname', state.temp_track_name)
  state.temp_track_name = new_name
  r.ImGui_Spacing(ctx)
  r.ImGui_Text(ctx, "Status:")
  local msg = state.status_msg or ""
  local status_col = 0x888899FF
  if msg:find("Error") then
    status_col = 0xCC4444FF
  elseif msg:find("Done") or msg:find("Rendered") or msg:find("Resampled") then
    status_col = 0x442D8C6D
  end
  r.ImGui_TextColored(ctx, status_col, msg)
end

local function panel_sampling()
  section_header("Sampling Mode")
  local half_w = (r.ImGui_GetContentRegionAvail(ctx) - 4) * 0.5
  if state.sampling_mode == 0 then
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x2D8C6DFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x33A07CFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x287A5EFF)
  else
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x202020FF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x333333FF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x444444FF)
  end
  if r.ImGui_Button(ctx, "Uniform", half_w, 28) then state.sampling_mode = 0 end
  r.ImGui_PopStyleColor(ctx, 3)
  r.ImGui_SameLine(ctx, 0, 4)
  if state.sampling_mode == 1 then
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x2D8C6DFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x33A07CFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x287A5EFF)
  else
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x202020FF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x333333FF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x444444FF)
  end
  if r.ImGui_Button(ctx, "Sequential", half_w, 28) then state.sampling_mode = 1 end
  r.ImGui_PopStyleColor(ctx, 3)
  show_tooltip("Uniform: grains cycle through all sources with random offsets.\nSequential: each source plays once in order, auto-sized to fit.")

  r.ImGui_Spacing(ctx)
  section_header("Sampling Direction")
  local dir_half_w = (r.ImGui_GetContentRegionAvail(ctx) - 4) * 0.5
  for row = 0, 1 do
    for col = 0, 1 do
      local idx = row * 2 + col + 1
      if col > 0 then r.ImGui_SameLine(ctx, 0, 4) end
      if state.playback_mode == idx then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x2D8C6DFF)
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
  r.ImGui_SameLine(ctx, 0, 4)
  if r.ImGui_Button(ctx, "Envelope Only", half_w, 28) then do_envelope_only() end
  if not can_util then r.ImGui_EndDisabled(ctx) end
  r.ImGui_Spacing(ctx)

  -- Title 2: Generation + 4 buttons in 2x2 (mirrors Sampling Direction grid)
  section_header("Generation")
  -- Row 1: Preview (sample grains + write envelopes to temp track)
  if not can_preview then r.ImGui_BeginDisabled(ctx) end
  if r.ImGui_Button(ctx, "Preview Stereo", half_w, 28) then do_generate(false, true) end
  r.ImGui_SameLine(ctx, 0, 4)
  if r.ImGui_Button(ctx, "Preview Mono", half_w, 28) then do_generate(true, true) end
  if not can_preview then r.ImGui_EndDisabled(ctx) end
  -- Row 2: Generate (bounce temp track + envelopes to a new rendered track)
  if not can_generate then r.ImGui_BeginDisabled(ctx) end
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x2D8C6DFF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x33A07CFF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x287A5EFF)
  if r.ImGui_Button(ctx, "Generate Stereo", half_w, 28) then do_render(false) end
  r.ImGui_SameLine(ctx, 0, 4)
  if r.ImGui_Button(ctx, "Generate Mono", half_w, 28) then do_render(true) end
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

  -- Duration dual-knob slider (mirrored at center, controls grain window compression)
  local dur_w = r.ImGui_GetContentRegionAvail(ctx)
  local dur_h = 22
  r.ImGui_InvisibleButton(ctx, '##duration', dur_w, dur_h)
  local dur_minx, dur_miny = r.ImGui_GetItemRectMin(ctx)
  local dur_dl = r.ImGui_GetWindowDrawList(ctx)
  local dur_mx, dur_my = r.ImGui_GetMousePos(ctx)
  local dur_active = r.ImGui_IsItemActive(ctx)
  local dur_hovered = r.ImGui_IsItemHovered(ctx)
  local MAX_COMPRESS = 0.30

  local left_x = dur_minx + state.inset * dur_w
  local right_x = dur_minx + (1 - state.inset) * dur_w
  local dur_cy = dur_miny + dur_h * 0.5

  r.ImGui_DrawList_AddRectFilled(dur_dl, dur_minx, dur_miny, dur_minx + dur_w, dur_miny + dur_h, 0xFF1A1A1A, 4)
  r.ImGui_DrawList_AddRect(dur_dl, dur_minx, dur_miny, dur_minx + dur_w, dur_miny + dur_h, 0xFF444444, 4)
  r.ImGui_DrawList_AddRectFilled(dur_dl, left_x, dur_miny, right_x, dur_miny + dur_h, 0x222D8C6D, 4)

  r.ImGui_DrawList_AddText(dur_dl, dur_minx + 6, dur_miny + 3, theme.TextDisabled, "Duration")

  if dur_active then
    local t = math.max(0, math.min(1, (dur_mx - dur_minx) / dur_w))
    local new_inset = math.min(t, 1 - t)
    state.inset = math.max(0, math.min(MAX_COMPRESS, new_inset))
    left_x = dur_minx + state.inset * dur_w
    right_x = dur_minx + (1 - state.inset) * dur_w
  end

  local active_pct = math.floor((1 - 2 * state.inset) * 100)
  local pct_str = active_pct .. "%"
  local pct_w = r.ImGui_CalcTextSize(ctx, pct_str)
  local pct_col = active_pct > 60 and 0xCCCCCCFF or (active_pct > 30 and 0xCCCC66FF or 0xCC6644FF)
  r.ImGui_DrawList_AddText(dur_dl, dur_minx + dur_w - pct_w - 6, dur_miny + 3, pct_col, pct_str)

  local knob_r = 6
  r.ImGui_DrawList_AddCircleFilled(dur_dl, left_x, dur_cy, knob_r + 2, 0x332D8C6D)
  r.ImGui_DrawList_AddCircleFilled(dur_dl, left_x, dur_cy, knob_r, theme.SliderGrab)
  r.ImGui_DrawList_AddCircleFilled(dur_dl, right_x, dur_cy, knob_r + 2, 0x332D8C6D)
  r.ImGui_DrawList_AddCircleFilled(dur_dl, right_x, dur_cy, knob_r, theme.SliderGrab)

  if dur_hovered or dur_active then
    show_tooltip("Controls the active duration of the grain window.\nBoth edges compress symmetrically toward the center,\ngiving the envelope more room for attack/release.")
  end
  r.ImGui_Spacing(ctx)

  -- Pitch vertical slider on the left of the visualizer
  r.ImGui_SetNextItemWidth(ctx, 20)
  local _, new_pitch = r.ImGui_VSliderDouble(ctx, '##pitch', 20, 160, state.pitch_shift, -12, 12, "%.0f")
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
    state.pitch_shift = 0.0
  end
  if r.ImGui_IsItemHovered(ctx) then
    show_tooltip("Pitch shift at the peak (semitones).\n+ = approach (up then down)\n- = recede (down then up)\n0 = no pitch envelope.\nDouble-click to reset.")
  end
  state.pitch_shift = new_pitch
  r.ImGui_SameLine(ctx)

  draw_preview(24)
  r.ImGui_SameLine(ctx)

  -- Dual-knob filter slider on the right of the visualizer
  local fslider_w = 20
  local fslider_h = 160
  r.ImGui_InvisibleButton(ctx, '##filter_slider', fslider_w, fslider_h)
  local fs_cx, fs_cy = r.ImGui_GetItemRectMin(ctx)
  local fs_dl = r.ImGui_GetWindowDrawList(ctx)
  local fs_mx, fs_my = r.ImGui_GetMousePos(ctx)
  local fs_active = r.ImGui_IsItemActive(ctx)
  local fs_hovered = r.ImGui_IsItemHovered(ctx)

  -- Track (background)
  r.ImGui_DrawList_AddRectFilled(fs_dl, fs_cx + 6, fs_cy, fs_cx + 14, fs_cy + fslider_h, 0xFF1A1A1A, 3)
  r.ImGui_DrawList_AddRect(fs_dl, fs_cx + 6, fs_cy, fs_cx + 14, fs_cy + fslider_h, 0xFF444444, 3)

  -- Frequency range is logarithmic: 20Hz..20000Hz
  local function hz_to_y(hz)
    local n = math.max(0.0, math.min(1.0, math.log(hz / 20.0) / math.log(24000.0 / 20.0)))
    return fs_cy + fslider_h - n * fslider_h
  end
  local function y_to_hz(y)
    local n = math.max(0.0, math.min(1.0, (fs_cy + fslider_h - y) / fslider_h))
    return 20.0 * (24000.0 / 20.0) ^ n
  end

  local top_knob_y = hz_to_y(state.filter_peak_freq)
  local bot_knob_y = hz_to_y(state.filter_base_freq)

  -- Fill between knobs (active filter range)
  r.ImGui_DrawList_AddRectFilled(fs_dl, fs_cx + 7, top_knob_y, fs_cx + 13, bot_knob_y, 0x442D8C6D, 2)

  -- Determine which knob to drag
  local mouse_clicked = r.ImGui_IsMouseClicked(ctx, 0)
  local mouse_down = r.ImGui_IsMouseDown(ctx, 0)
  local dist_top = math.abs(fs_my - top_knob_y)
  local dist_bot = math.abs(fs_my - bot_knob_y)

  if mouse_clicked and (fs_active or fs_hovered) then
    if dist_top < dist_bot and dist_top < 12 then
      filter_top_dragging = true
    elseif dist_bot < 12 then
      filter_bottom_dragging = true
    end
  end
  if not mouse_down then
    filter_top_dragging = false
    filter_bottom_dragging = false
  end

  -- Min gap between knobs (in Hz) to prevent overlap
  local min_hz_gap = 100.0

  if filter_top_dragging then
    local new_y = math.max(fs_cy, math.min(bot_knob_y - 4, fs_my))
    local new_hz = y_to_hz(new_y)
    new_hz = math.max(state.filter_base_freq + min_hz_gap, math.min(20000.0, new_hz))
    state.filter_peak_freq = new_hz
  end
  if filter_bottom_dragging then
    local new_y = math.min(fs_cy + fslider_h, math.max(top_knob_y + 4, fs_my))
    local new_hz = y_to_hz(new_y)
    new_hz = math.min(state.filter_peak_freq - min_hz_gap, math.max(20.0, new_hz))
    state.filter_base_freq = new_hz
  end

  -- Recompute knob positions after drag
  top_knob_y = hz_to_y(state.filter_peak_freq)
  bot_knob_y = hz_to_y(state.filter_base_freq)

  -- Draw knobs (top = bright green, bottom = dim green)
  r.ImGui_DrawList_AddCircleFilled(fs_dl, fs_cx + 10, top_knob_y, 7, 0xFF2D8C6D)
  r.ImGui_DrawList_AddCircleFilled(fs_dl, fs_cx + 10, top_knob_y, 4, 0xFF33A07C)
  r.ImGui_DrawList_AddCircleFilled(fs_dl, fs_cx + 10, bot_knob_y, 7, 0xFF1A5C4A)
  r.ImGui_DrawList_AddCircleFilled(fs_dl, fs_cx + 10, bot_knob_y, 4, 0xFF22705A)

  if fs_hovered or filter_top_dragging or filter_bottom_dragging then
    local filter_off_now =
      state.filter_peak_freq >= 20000.0 and
      state.filter_base_freq >= state.filter_peak_freq - 100.5
    local tip = string.format("Peak: %.0f Hz\nBase: %.0f Hz", state.filter_peak_freq, state.filter_base_freq)
    if filter_off_now then
      tip = tip .. "\n(both knobs at max -- EQ doppler bypassed)"
    end
    show_tooltip(tip)
  end

  -- ── CUSTOM PAN KNOB ──
  -- oOo at center (deadzone snap), >>> on left, <<< on right
  r.ImGui_Dummy(ctx, 0, 2)
  local pan_w = r.ImGui_GetContentRegionAvail(ctx)
  local pan_h = 22
  r.ImGui_InvisibleButton(ctx, '##pan', pan_w, pan_h)
  local pan_minx, pan_miny = r.ImGui_GetItemRectMin(ctx)
  local pan_dl = r.ImGui_GetWindowDrawList(ctx)
  local pan_mx, pan_my = r.ImGui_GetMousePos(ctx)
  local pan_active = r.ImGui_IsItemActive(ctx)
  local pan_hovered = r.ImGui_IsItemHovered(ctx)

  -- Track background
  r.ImGui_DrawList_AddRectFilled(pan_dl, pan_minx, pan_miny, pan_minx + pan_w, pan_miny + pan_h, 0xFF1A1A1A, 4)
  r.ImGui_DrawList_AddRect(pan_dl, pan_minx, pan_miny, pan_minx + pan_w, pan_miny + pan_h, 0xFF444444, 4)

  -- Direction labels inside the slider
  r.ImGui_DrawList_AddText(pan_dl, pan_minx + 6, pan_miny + 3, theme.TextDisabled, "Left to Right")
  local rtl_w = r.ImGui_CalcTextSize(ctx, "Right to Left")
  r.ImGui_DrawList_AddText(pan_dl, pan_minx + pan_w - rtl_w - 6, pan_miny + 3, theme.TextDisabled, "Right to Left")

  local pan_cx = pan_minx + pan_w * 0.5
  local pan_cy = pan_miny + pan_h * 0.5
  -- Center tick marks the neutral position
  r.ImGui_DrawList_AddLine(pan_dl, pan_cx, pan_miny + 3, pan_cx, pan_miny + pan_h - 3, 0x66444444, 1)

  -- Dead zone around center: values within this band snap to 0
  local pan_dead = 0.06

  -- Drag to set value; value spans -1..+1 across the track width
  if pan_active and r.ImGui_IsMouseDown(ctx, 0) then
    local t = math.max(0.0, math.min(1.0, (pan_mx - pan_minx) / pan_w))
    local raw = t * 2.0 - 1.0
    if math.abs(raw) < pan_dead then
      state.pan_value = 0.0
    else
      state.pan_value = raw
    end
  end
  if pan_hovered and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
    state.pan_value = 0.0
  end

  -- Knob position from current value
  local knob_x = pan_minx + (state.pan_value + 1.0) * 0.5 * pan_w

  -- In the dead zone the knob becomes oOo: a head (large circle) with two ears (small circles)
  if math.abs(state.pan_value) < pan_dead then
    local ear_r = 2.2
    local head_r = 4.6
    local ear_dx = head_r + ear_r - 0.5
    r.ImGui_DrawList_AddCircleFilled(pan_dl, knob_x - ear_dx, pan_cy, ear_r, theme.SliderGrab)
    r.ImGui_DrawList_AddCircleFilled(pan_dl, knob_x,          pan_cy, head_r, theme.SliderGrab)
    r.ImGui_DrawList_AddCircleFilled(pan_dl, knob_x + ear_dx, pan_cy, ear_r, theme.SliderGrab)
  else
    -- Three triangles: >>> when on left half, <<< when on right half
    local s = 5.5
    local dx = s * 1.7
    local pointing_right = state.pan_value <= 0.0
    for i = -1, 1 do
      local tcx = knob_x + i * dx
      if pointing_right then
        r.ImGui_DrawList_AddTriangleFilled(pan_dl, tcx + s, pan_cy, tcx - s, pan_cy - s, tcx - s, pan_cy + s, theme.SliderGrab)
      else
        r.ImGui_DrawList_AddTriangleFilled(pan_dl, tcx - s, pan_cy, tcx + s, pan_cy - s, tcx + s, pan_cy + s, theme.SliderGrab)
      end
    end
  end

  if pan_hovered or pan_active then
    show_tooltip("Center = no pan sweep.\nLeft = L->R sweep.\nRight = R->L sweep.\nEdges = 100% strength.\nDouble-click to reset.")
  end

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
  local vis, open = r.ImGui_Begin(ctx, 'GranularWhoosh v1.0.0', true, win_flags)

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
