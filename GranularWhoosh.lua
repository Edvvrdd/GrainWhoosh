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

-- Constants
local PLAYBACK_MODES = {"Forward", "Reverse", "Ping-Pong", "Random"}
local SAMPLING_MODES = {"Uniform", "Sequential"}
local PITCH_DIRS = {"Up → down (approach)", "Down → up"}
local PAN_DIRS = {"Left → right", "Right → left"}

local grain_vis_data = {}
for i = 1, 300 do
  table.insert(grain_vis_data, {
    x_frac = math.random(),
    h_frac = 0.2 + math.random() * 0.8,
    color_idx = math.random(1, 3)
  })
end

-- Initial State
local state = {
  -- Source / Sampling
  sampling_mode = 0, -- 0 = Uniform, 1 = Sequential
  grain_size = 80.0,   -- Uniform: 10-500ms grain length
  grain_density = 60.0,   -- 0-100 percentage (maps to density/crossfade)
  pos_rnd = 0.15,
  randomness = 0.2,
  playback_mode = 1, -- 1-based index for combo
  inset = 0.0,         -- 0..0.45 — inset grains by this fraction each side

  -- Source Info (from Reaper)
  sel_start = 0,
  sel_end = 0,
  sel_duration = 0,
  folder_track = nil,
  folder_name = "None",
  is_folder = false,
  child_count = 0,

  -- Debug info
  debug_info = {},
  
  -- Envelope
  peak_pos = 0.5,
  hold_time = 0.0,
  attack = 0.5,
  release = 0.5,
  front_spill = 0.0,
  back_spill = 0.0,
  comp_strength = 0.0,
  
  -- Doppler
  pitch_range = 6.0,
  pitch_direction = 1,
  pitch_peak_offset = 0.0,
  filter_base_freq = 200.0,
  filter_peak_freq = 15000.0,
  filter_peak_offset = 0.0,
  pan_amount = 1.0,
  pan_strength = 0.5,
  pan_direction = 1,
  pan_peak_offset = 0.0,
  enable_doppler = true,
  
  -- Output / Generation
  temp_track_name = "GW_Temp",
  is_mono = false,
  generated_start = 0,
  generated_end = 0,
  status_msg = "Ready — select a folder and time range",
  is_generating = false,
  has_generated_item = false,
  temp_track_idx = 0
}

---------------------------------------------------------------------
-- UI Helper Functions
---------------------------------------------------------------------
function labeled_slider(label, value, min, max, format)
  r.ImGui_Text(ctx, label)
  r.ImGui_SetNextItemWidth(ctx, -1)
  local changed, new_value = r.ImGui_SliderDouble(ctx, '##' .. label, value, min, max, format)
  if changed then return new_value end
  return value
end

function labeled_combo(label, idx, items)
  r.ImGui_Text(ctx, label)
  r.ImGui_SetNextItemWidth(ctx, -1)
  local changed, new_idx = r.ImGui_Combo(ctx, '##'..label, idx, table.concat(items, '\0')..'\0')
  if changed then return new_idx end
  return idx
end

function draw_preview()
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local cx, cy = r.ImGui_GetCursorScreenPos(ctx)
  local W = r.ImGui_GetContentRegionAvail(ctx)
  local H = 64

  -- Dark background
  r.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + W, cy + H, 0xFF0A0A0F, 3)
  r.ImGui_DrawList_AddRect(dl, cx, cy, cx + W, cy + H, 0x33333333, 3)

  -- ── GRAIN BACKGROUND ──
  if state.sampling_mode == 1 then
    -- Sequential: dark sectioned blocks with neon borders
    local num_sources = math.max(1, math.min(10, state.child_count))
    local block_w = W / num_sources
    local overlap_w = block_w * (state.grain_density / 100) * 0.5
    
    local fill_colors = {0x22223344, 0x22332244, 0x22224433}
    local border_colors = {0x44445566, 0x44554466, 0x44446655}
    
    local colors = {}
    for i = 1, num_sources do
      local color_idx = ((i - 1) % 3) + 1
      if i > 1 and color_idx == colors[i - 1] then
        color_idx = (color_idx % 3) + 1
      end
      colors[i] = color_idx
    end
    
    for i = 1, num_sources do
      local fill = fill_colors[colors[i]]
      local border = border_colors[colors[i]]
      local x_start = cx + ((i - 1) * block_w)
      local x_end = x_start + block_w + overlap_w
      
      r.ImGui_DrawList_AddRectFilled(dl, x_start, cy + 4, math.min(cx + W - 2, x_end), cy + H - 4, fill, 2)
      r.ImGui_DrawList_AddLine(dl, x_start, cy + 4, x_start, cy + H - 4, border, 2)
      
      local txt = tostring(i)
      local txt_w = r.ImGui_CalcTextSize(ctx, txt)
      r.ImGui_DrawList_AddText(dl, x_start + (block_w - txt_w) * 0.5, cy + H * 0.35, 0x88FFFFFF, txt)
    end
  else
    -- Uniform: dark dense texture
    local density_norm = state.grain_density / 100
    local num_grains = math.floor(50 + (250 * density_norm))
    local grain_colors = {0x22334455, 0x22553344, 0x22335544}
    
    for i = 1, num_grains do
      local g = grain_vis_data[i]
      local x = cx + (g.x_frac * W)
      local y_start = cy + (H * (1.0 - g.h_frac) / 2)
      local y_end = y_start + (H * g.h_frac)
      local alpha_fade = math.floor(0x55 * (1.2 - density_norm))
      local color = (grain_colors[g.color_idx] & 0x00FFFFFF) | (alpha_fade << 24)
      r.ImGui_DrawList_AddLine(dl, x, y_start, x, y_end, color, 1.0)
    end
  end

  -- ── ENVELOPE CURVES ──
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
  
  local pitch_pk_start = math.max(0, math.min(1.0 - hold, peak_start + state.pitch_peak_offset / dur))
  local pitch_pk_end = math.min(1.0, pitch_pk_start + hold)
  local filter_pk_start = math.max(0, math.min(1.0 - hold, peak_start + state.filter_peak_offset / dur))
  local filter_pk_end = math.min(1.0, filter_pk_start + hold)
  
  local function get_v(pk_s, pk_e)
    return function(t)
      if t <= pk_s then
        local lt = (pk_s > 0) and (t / pk_s) or 0
        return bez(lt, 0, 1, att, -rel)
      elseif t >= pk_e then
        local lt = (pk_e < 1) and ((t - pk_e) / (1 - pk_e)) or 0
        return bez(lt, 1, 0, -rel, 0)
      else
        return 1.0
      end
    end
  end
  
  local segments = 120
  local pts_vol = {}
  local pts_pitch = {}
  local pts_filter = {}
  
  for i = 0, segments do
    local t = i / segments
    local x = cx + t * W
    
    local v_vol = math.max(0, math.min(1, get_v(peak_start, peak_end)(t)))
    pts_vol[#pts_vol+1] = x
    pts_vol[#pts_vol+1] = cy + H - v_vol * (H - 6) - 3
    
    if state.enable_doppler then
      local v_pitch = math.max(0, math.min(1, get_v(pitch_pk_start, pitch_pk_end)(t)))
      local v_filter = math.max(0, math.min(1, get_v(filter_pk_start, filter_pk_end)(t)))
      pts_pitch[#pts_pitch+1] = x
      pts_pitch[#pts_pitch+1] = cy + H - v_pitch * (H - 6) - 3
      pts_filter[#pts_filter+1] = x
      pts_filter[#pts_filter+1] = cy + H - v_filter * (H - 6) - 3
    end
  end
  
  if state.enable_doppler then
    -- Filter (neon green)
    local arr_f = r.new_array(pts_filter)
    r.ImGui_DrawList_AddPolyline(dl, arr_f, 0x4400FF88, 0, 4.0)
    r.ImGui_DrawList_AddPolyline(dl, arr_f, 0xCC00FF88, 0, 1.5)
    -- Pitch (neon magenta)
    local arr_p = r.new_array(pts_pitch)
    r.ImGui_DrawList_AddPolyline(dl, arr_p, 0x44FF00FF, 0, 4.0)
    r.ImGui_DrawList_AddPolyline(dl, arr_p, 0xCCFF00FF, 0, 1.5)
  end
  
  -- Volume (neon cyan)
  local arr_v = r.new_array(pts_vol)
  r.ImGui_DrawList_AddPolyline(dl, arr_v, 0x4400FFFF, 0, 4.0)
  r.ImGui_DrawList_AddPolyline(dl, arr_v, 0xCC00FFFF, 0, 1.5)
  
  -- ── LEGEND ──
  local function dot(x, y, col)
    r.ImGui_DrawList_AddCircleFilled(dl, x, y, 3, col)
  end
  
  dot(cx + 5, cy + 5, 0xFF00FFFF)
  r.ImGui_DrawList_AddText(dl, cx + 12, cy + 1, 0xFF00FFFF, "Vol")
  
  if state.enable_doppler then
    dot(cx + 5, cy + 17, 0xFF00FF88)
    r.ImGui_DrawList_AddText(dl, cx + 12, cy + 13, 0xFF00FF88, "Filter")
    dot(cx + 5, cy + 29, 0xFFFF00FF)
    r.ImGui_DrawList_AddText(dl, cx + 12, cy + 25, 0xFFFF00FF, "Pitch")
  end

  r.ImGui_Dummy(ctx, W, H)
end

---------------------------------------------------------------------
-- Reaper Data Functions
---------------------------------------------------------------------
function refresh_source_info()
  -- Reset counts
  state.child_count = 0
  state.folder_track = nil
  state.is_folder = false
  state.folder_name = "None"
  state.debug_info = {} -- Store detailed debug info

  -- Get time selection
  local ts, te = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  state.sel_start = ts
  state.sel_end = te
  state.sel_duration = te - ts

  -- Get selected track
  local sel_track = r.GetSelectedTrack(0, 0)
  if not sel_track then 
    table.insert(state.debug_info, "No track selected")
    return 
  end

  -- Get track info
  local track_num = r.GetMediaTrackInfo_Value(sel_track, 'IP_TRACKNUMBER')
  local _, track_name = r.GetSetMediaTrackInfo_String(sel_track, 'P_NAME', '', false)
  table.insert(state.debug_info, "Selected: Track " .. track_num .. " - " .. track_name)

  -- Check if it's a folder
  local folder_depth = r.GetMediaTrackInfo_Value(sel_track, 'I_FOLDERDEPTH')
  table.insert(state.debug_info, "Folder depth: " .. folder_depth)
  
  if folder_depth == 1 then
    state.folder_track = sel_track
    state.is_folder = true
    state.folder_name = track_name

    -- Count valid children
    -- IP_TRACKNUMBER is 1-based, GetTrack uses 0-based
    local folder_0based_idx = track_num - 1
    local total_tracks = r.CountTracks(0)
    table.insert(state.debug_info, "Total tracks: " .. total_tracks)
    table.insert(state.debug_info, "Folder 0-based idx: " .. folder_0based_idx)
    
    for i = folder_0based_idx + 1, total_tracks - 1 do
      local child_track = r.GetTrack(0, i)
      if not child_track then break end
      
      local child_depth = r.GetMediaTrackInfo_Value(child_track, 'I_FOLDERDEPTH')
      local child_num = r.GetMediaTrackInfo_Value(child_track, 'IP_TRACKNUMBER')
      local _, child_name = r.GetSetMediaTrackInfo_String(child_track, 'P_NAME', '', false)
      local item_count = r.CountTrackMediaItems(child_track)
      
      table.insert(state.debug_info, "  Child " .. child_num .. " (" .. child_name .. "): depth=" .. child_depth .. ", items=" .. item_count)
      
      -- If we hit end of this folder (negative depth), stop
      -- Normal child tracks have depth=0, folder ends have depth<0
      if child_depth < 0 then 
        table.insert(state.debug_info, "  -> Hit end of folder (depth=" .. child_depth .. ")")
        break 
      end

      if item_count > 0 then
        state.child_count = state.child_count + 1
        table.insert(state.debug_info, "  -> VALID SOURCE!")
      end
    end
    table.insert(state.debug_info, "Total valid children: " .. state.child_count)
  else
    table.insert(state.debug_info, "Not a folder track")
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
  for i = 0, r.CountTracks(0) - 1 do
    local track = r.GetTrack(0, i)
    local _, name = r.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)
    if name == state.temp_track_name then
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

function do_generate(is_mono)
  if not validate_can_generate() then return end
  
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
  
  -- Get time selection with edge inset
  local inset = math.max(0.0, math.min(0.45, state.inset))
  local inset_s = state.sel_duration * inset
  local win_start = state.sel_start + inset_s
  local win_end = state.sel_end - inset_s
  local win_dur = math.max(0.001, win_end - win_start)
  
  -- Collect valid source tracks
  local source_tracks = {}
  local folder_idx = r.GetMediaTrackInfo_Value(state.folder_track, 'IP_TRACKNUMBER') - 1
  for i = folder_idx + 1, r.CountTracks(0) - 1 do
    local track = r.GetTrack(0, i)
    if not track then break end
    local depth = r.GetMediaTrackInfo_Value(track, 'I_FOLDERDEPTH')
    if depth < 0 then break end
    if r.CountTrackMediaItems(track) > 0 then
      table.insert(source_tracks, track)
    end
  end
  
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
            r.SetMediaItemTakeInfo_Value(new_take, 'D_STARTOFFS', 0)
            
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
            
            -- Positional randomness
            local rnd_range = state.pos_rnd * max_offs
            base_pos = base_pos + (math.random() - 0.5) * 2.0 * rnd_range
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
  
  r.defer(apply_volume_envelope)
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

function do_render()
  if not state.has_generated_item then return end

  -- Find temp track
  local temp_track, temp_idx = find_temp_track()
  if not temp_track then
    state.status_msg = "Temp track not found — run Generate first"
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

function get_or_add_comp_fx(track)
  local cnt = r.TrackFX_GetCount(track)
  for i = 0, cnt - 1 do
    local _, nm = r.TrackFX_GetFXName(track, i)
    if nm:find('ReaComp', 1, true) then
      return i
    end
  end
  local idx = r.TrackFX_AddByName(track, 'JS: ReaComp', false, -1)
  if idx < 0 then
    idx = r.TrackFX_AddByName(track, 'VST: ReaComp (Cockos)', false, -1)
  end
  if idx < 0 then
    idx = r.TrackFX_AddByName(track, 'VST3: ReaComp (Cockos)', false, -1)
  end
  return idx
end

function apply_comp(track, strength)
  local fx_idx = get_or_add_comp_fx(track)
  if fx_idx < 0 then return end
  r.TrackFX_SetEnabled(track, fx_idx, true)

  if strength <= 0 then
    -- Bypass when slider is at 0
    r.TrackFX_SetEnabled(track, fx_idx, false)
    return
  end

  local threshold_norm = 1.0 - (strength / 100.0)
  local ratio_norm = strength / 100.0
  local attack_norm = 0.05
  local release_norm = 0.1
  local rms_norm = 0.0
  local makeup_norm = 0.5

  r.TrackFX_SetParamNormalized(track, fx_idx, 0, threshold_norm)
  r.TrackFX_SetParamNormalized(track, fx_idx, 1, ratio_norm)
  r.TrackFX_SetParamNormalized(track, fx_idx, 2, attack_norm)
  r.TrackFX_SetParamNormalized(track, fx_idx, 3, release_norm)
  r.TrackFX_SetParamNormalized(track, fx_idx, 4, rms_norm)
  r.TrackFX_SetParamNormalized(track, fx_idx, 5, makeup_norm)
end

function get_or_add_pitch_fx(track)
  local cnt = r.TrackFX_GetCount(track)
  for i = 0, cnt - 1 do
    local _, nm = r.TrackFX_GetFXName(track, i)
    if nm:find('ReaPitch', 1, true) then
      return i
    end
  end
  local idx = r.TrackFX_AddByName(track, 'VST: ReaPitch (Cockos)', false, -1)
  if idx < 0 then
    idx = r.TrackFX_AddByName(track, 'VST3: ReaPitch (Cockos)', false, -1)
  end
  return idx
end

function get_or_add_filter_fx(track)
  local cnt = r.TrackFX_GetCount(track)
  for i = 0, cnt - 1 do
    local _, nm = r.TrackFX_GetFXName(track, i)
    if nm:find('ReaEQ', 1, true) then
      return i
    end
  end
  local idx = r.TrackFX_AddByName(track, 'VST: ReaEQ (Cockos)', false, -1)
  if idx < 0 then
    idx = r.TrackFX_AddByName(track, 'VST3: ReaEQ (Cockos)', false, -1)
  end
  return idx
end

local function write_doppler_env(env, v_floor, v_peak, v_floor_end, env_start, peak_start, peak_end, env_end, att, rel)
  if not env then return end
  local n = r.CountEnvelopePoints(env)
  for i = n - 1, 0, -1 do
    r.DeleteEnvelopePointEx(env, -1, i)
  end
  
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

function apply_doppler_envelopes()
  if not state.enable_doppler then return end
  
  local temp_track, _ = find_temp_track()
  if not temp_track then return end
  if not state.has_generated_item then return end

  local sel_start = state.generated_start
  local sel_end = state.generated_end
  local duration = sel_end - sel_start
  if duration <= 0 then return end

  local env_start = sel_start - state.front_spill
  local env_end = sel_end + state.back_spill

  local hold_s = duration * state.hold_time
  local peak_center = sel_start + duration * state.peak_pos
  local anchor_start = math.max(env_start, peak_center - hold_s / 2)
  local anchor_end = math.min(env_end, anchor_start + hold_s)

  if anchor_end > env_end then
    anchor_end = env_end
    anchor_start = math.max(env_start, anchor_end - hold_s)
  end

  local att = math.max(-1.0, math.min(1.0, state.attack))
  local rel = math.max(-1.0, math.min(1.0, state.release))

  -- Pitch envelope
  local pitch_idx = get_or_add_pitch_fx(temp_track)
  if pitch_idx >= 0 then
    r.TrackFX_SetEnabled(temp_track, pitch_idx, true)
    local pitch_env = r.GetFXEnvelope(temp_track, pitch_idx, 0, true)
    if pitch_env then
      local st = math.max(0.0, math.min(24.0, state.pitch_range))
      local centre = 24 / 48
      local signed = (state.pitch_direction == 1) and st or -st
      local peak_n = (signed + 24) / 48
      
      local p_start = math.max(env_start, math.min(env_end, anchor_start + state.pitch_peak_offset))
      local p_end = math.max(env_start, math.min(env_end, anchor_end + state.pitch_peak_offset))
      
      write_doppler_env(pitch_env, centre, peak_n, centre, env_start, p_start, p_end, env_end, att, rel)
    end
  end

  -- Filter envelope (ReaEQ lowpass)
  local filter_idx = get_or_add_filter_fx(temp_track)
  if filter_idx >= 0 then
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
      
      local f_start = math.max(env_start, math.min(env_end, anchor_start + state.filter_peak_offset))
      local f_end = math.max(env_start, math.min(env_end, anchor_end + state.filter_peak_offset))
      
      write_doppler_env(filter_env, norm_base, norm_peak, norm_base, env_start, f_start, f_end, env_end, att, rel)
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
    local pn_start = math.max(env_start, math.min(env_end, anchor_start + state.pan_peak_offset))
    local pn_end = math.max(env_start, math.min(env_end, anchor_end + state.pan_peak_offset))
    
    if state.is_mono then
      write_doppler_env(pan_env, 0.0, 0.0, 0.0, env_start, pn_start, pn_end, env_end, att, rel)
    else
      local str = state.pan_strength
      local sign = (state.pan_direction == 1) and 1 or -1
      write_doppler_env(pan_env, -str * sign, 0.0, str * sign, env_start, pn_start, pn_end, env_end, att, rel)
    end
  end
end

function apply_volume_envelope()
  local temp_track, _ = find_temp_track()
  if not temp_track then return end
  if not state.has_generated_item then return end

  local sel_start = state.generated_start
  local sel_end = state.generated_end
  local duration = sel_end - sel_start
  if duration <= 0 then return end

  r.SetMediaTrackInfo_Value(temp_track, 'I_AUTOMODE', 1)

  local vol_env = r.GetTrackEnvelopeByName(temp_track, 'Volume')
  if not vol_env then
    r.SetOnlyTrackSelected(temp_track)
    r.Main_OnCommand(40406, 0)
    vol_env = r.GetTrackEnvelopeByName(temp_track, 'Volume')
  end
  if not vol_env then return end

  local env_min = r.ScaleToEnvelopeMode(1, 0.0)
  local env_max = r.ScaleToEnvelopeMode(1, 1.0)

  local n = r.CountEnvelopePoints(vol_env)
  for i = n - 1, 0, -1 do
    r.DeleteEnvelopePointEx(vol_env, -1, i)
  end

  local env_start = sel_start - state.front_spill
  local env_end = sel_end + state.back_spill

  local hold_s = duration * state.hold_time
  local peak_center = sel_start + duration * state.peak_pos
  local peak_start = math.max(env_start, peak_center - hold_s / 2)
  local peak_end = math.min(env_end, peak_start + hold_s)

  if peak_end > env_end then
    peak_end = env_end
    peak_start = math.max(env_start, peak_end - hold_s)
  end

  local att = math.max(-1.0, math.min(1.0, state.attack))
  local rel = math.max(-1.0, math.min(1.0, state.release))

  if math.abs(peak_start - peak_end) > 0.001 then
    r.InsertEnvelopePoint(vol_env, env_start,  env_min, 5,  att, false, false)
    r.InsertEnvelopePoint(vol_env, peak_start, env_max, 0,  0.0, false, false)
    r.InsertEnvelopePoint(vol_env, peak_end,   env_max, 5, -rel, false, false)
    r.InsertEnvelopePoint(vol_env, env_end,    env_min, 5,  0.0, false, false)
  else
    r.InsertEnvelopePoint(vol_env, env_start,  env_min, 5,  att, false, false)
    r.InsertEnvelopePoint(vol_env, peak_start, env_max, 5, -rel, false, false)
    r.InsertEnvelopePoint(vol_env, env_end,    env_min, 5,  0.0, false, false)
  end

  r.Envelope_SortPoints(vol_env)
  apply_comp(temp_track, state.comp_strength)
  apply_doppler_envelopes()
  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
end

---------------------------------------------------------------------
-- Main Draw Loop
---------------------------------------------------------------------
function loop()
  refresh_source_info()

  r.ImGui_SetNextWindowSize(ctx, 640, 540, r.ImGui_Cond_FirstUseEver())
  local vis, open = r.ImGui_Begin(ctx, 'GranularWhoosh v1.0.0', true, r.ImGui_WindowFlags_NoCollapse())

  if vis then
    local table_flags = r.ImGui_TableFlags_SizingStretchSame()
    
    if r.ImGui_BeginTable(ctx, "MainLayout", 3, table_flags) then
      r.ImGui_TableNextRow(ctx)
      
      -- COLUMN 1: SOURCE / SAMPLING
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, "SOURCE / SAMPLING")
      r.ImGui_Separator(ctx)
      r.ImGui_Spacing(ctx)
      
      state.sampling_mode = labeled_combo("Sampling Mode", state.sampling_mode, SAMPLING_MODES)
      r.ImGui_Separator(ctx)

      state.grain_size = labeled_slider("Grain Size", state.grain_size, 10, 500, "%.0f ms")
      state.grain_density = labeled_slider("Grain Density", state.grain_density, 0, 100, "%.0f%%")
      r.ImGui_TextDisabled(ctx, string.format("  = %.0f%% overlap", state.grain_density))
      
      r.ImGui_Separator(ctx)
      state.pos_rnd = labeled_slider("Positional Randomness", state.pos_rnd, 0, 1, "%.2f")
      state.randomness = labeled_slider("Pitch/Direction Randomness", state.randomness, 0, 1, "%.2f")
      state.playback_mode = labeled_combo("Sampling Direction", state.playback_mode, PLAYBACK_MODES)

      -- COLUMN 2: VOLUME ENVELOPE
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, "VOLUME ENVELOPE")
      r.ImGui_Separator(ctx)
      r.ImGui_Spacing(ctx)
      
      state.peak_pos = labeled_slider("Peak Position", state.peak_pos, 0.01, 0.99, "%.2f")
      state.hold_time = labeled_slider("Hold Time", state.hold_time, 0, 0.5, "%.2f")
      state.attack = labeled_slider("Rise Tension", state.attack, -1.0, 1.0, "%.2f")
      state.release = labeled_slider("Fall Tension", state.release, -1.0, 1.0, "%.2f")
      state.front_spill = labeled_slider("Front Spill", state.front_spill, 0, 2.0, "%.2f s")
      state.back_spill = labeled_slider("Back Spill", state.back_spill, 0, 2.0, "%.2f s")
      state.comp_strength = labeled_slider("Compression", state.comp_strength, 0, 100, "%.0f%%")

      -- COLUMN 3: OUTPUT / GENERATION
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, "OUTPUT / GENERATION")
      r.ImGui_Separator(ctx)
      r.ImGui_Spacing(ctx)
      
      state.inset = labeled_slider("Inset", state.inset, 0, 0.45, "%.2f")
      r.ImGui_Spacing(ctx)
      
      r.ImGui_Text(ctx, "Track Name")
      r.ImGui_SetNextItemWidth(ctx, -1)
      local _, new_name = r.ImGui_InputText(ctx, '##tempname', state.temp_track_name)
      state.temp_track_name = new_name
      r.ImGui_Spacing(ctx)
      
      r.ImGui_Text(ctx, "Status:")
      r.ImGui_TextDisabled(ctx, state.status_msg)
      r.ImGui_Spacing(ctx)
      
      local can_generate = state.is_folder and state.child_count > 0 and state.sel_duration > 0 and not state.is_generating
      
      if not can_generate then r.ImGui_BeginDisabled(ctx) end
      
      if r.ImGui_Button(ctx, "GENERATE STEREO", -1, 28) then
        do_generate(false)
      end
      r.ImGui_Spacing(ctx)
      
      if r.ImGui_Button(ctx, "GENERATE MONO", -1, 28) then
        do_generate(true)
      end
      
      if not can_generate then r.ImGui_EndDisabled(ctx) end
      
      r.ImGui_Spacing(ctx)
      r.ImGui_Separator(ctx)
      r.ImGui_Spacing(ctx)
      
      local can_resample = state.has_generated_item
      if not can_resample then r.ImGui_BeginDisabled(ctx) end
      
      if r.ImGui_Button(ctx, "RESAMPLE TO FOLDER", -1, 28) then
        do_resample()
      end
      
      if not can_resample then r.ImGui_EndDisabled(ctx) end
      
      r.ImGui_Spacing(ctx)
      
      if not can_resample then r.ImGui_BeginDisabled(ctx) end
      
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0xFF4488AA)
      if r.ImGui_Button(ctx, "RENDER", -1, 36) then
        do_render()
      end
      r.ImGui_PopStyleColor(ctx)
      
      if not can_resample then r.ImGui_EndDisabled(ctx) end
      
      r.ImGui_EndTable(ctx)
    end
    
    -- DOPPLER ROW
    r.ImGui_Text(ctx, "DOPPLER")
    r.ImGui_SameLine(ctx)
    local changed, val = r.ImGui_Checkbox(ctx, "Enable##doppler", state.enable_doppler)
    if changed then state.enable_doppler = val end
    r.ImGui_Separator(ctx)
    
    if r.ImGui_BeginTable(ctx, "DopplerLayout", 3, r.ImGui_TableFlags_SizingStretchSame()) then
      -- Pitch column
      r.ImGui_TableNextRow(ctx)
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, "PITCH")
      r.ImGui_Separator(ctx)
      
      state.pitch_range = labeled_slider("Intensity", state.pitch_range, 0, 24, "%.1f st")
      state.pitch_direction = labeled_combo("Pitch Dir", state.pitch_direction, PITCH_DIRS)
      state.pitch_peak_offset = labeled_slider("Pitch Offset", state.pitch_peak_offset, -1.0, 1.0, "%.2f s")
      
      -- Filter column
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, "FILTER")
      r.ImGui_Separator(ctx)
      
      state.filter_base_freq = labeled_slider("Base Freq", state.filter_base_freq, 20, 2000, "%.0f Hz")
      state.filter_peak_freq = labeled_slider("Peak Freq", state.filter_peak_freq, 1000, 20000, "%.0f Hz")
      state.filter_peak_offset = labeled_slider("Filter Offset", state.filter_peak_offset, -1.0, 1.0, "%.2f s")
      
      -- Pan column
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_Text(ctx, "PAN")
      r.ImGui_Separator(ctx)
      
      state.pan_strength = labeled_slider("Strength", state.pan_strength, 0, 1.0, "%.2f")
      state.pan_direction = labeled_combo("Pan Dir", state.pan_direction, PAN_DIRS)
      state.pan_peak_offset = labeled_slider("Pan Offset", state.pan_peak_offset, -1.0, 1.0, "%.2f s")
      
      r.ImGui_EndTable(ctx)
    end
    
    -- PREVIEW VISUALIZER
    r.ImGui_Spacing(ctx)
    draw_preview()
  end

  r.ImGui_End(ctx)

  if open then
    r.defer(loop)
  end
end

r.defer(loop)
