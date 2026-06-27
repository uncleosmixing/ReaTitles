-- @description ReaTitles Smart Split
-- @version 1.4.1
-- @author ReaTitles
-- @about
--   Split selected subtitle/audio groups at the edit cursor.
--   Subtitle text is divided using Whisper word timestamps.

local r = reaper
local EPSILON = 0.000001
local script_source = (debug.getinfo(1, "S") or {}).source or ""
local script_dir = script_source:match("^@(.+[\\/])") or ""
local model_ok, subtitle_model =
  pcall(dofile, script_dir .. "rt_subtitle_model.lua")
if not model_ok then
  r.ShowMessageBox(
    "ReaTitles installation is incomplete: rt_subtitle_model.lua is missing.\n\n" ..
    tostring(subtitle_model),
    "ReaTitles dependency error", 0)
  return
end

local montage_ok, montage_model =
  pcall(dofile, script_dir .. "rt_montage_model.lua")
if not montage_ok then
  r.ShowMessageBox(
    "ReaTitles installation is incomplete: rt_montage_model.lua is missing.\n\n" ..
    tostring(montage_model),
    "ReaTitles dependency error", 0)
  return
end

local function get_string(item, key)
  local _, value = r.GetSetMediaItemInfo_String(item, key, "", false)
  return value or ""
end

local function set_string(item, key, value)
  r.GetSetMediaItemInfo_String(item, key, value or "", true)
end

local function fallback_split_text(text, ratio)
  text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return "", "" end
  ratio = math.max(0, math.min(1, ratio))
  local target = #text * ratio
  local candidates = {}

  -- Prefer a sentence boundary near the acoustic cut.
  local search_from = 1
  while true do
    local s, e = text:find("[%.%!%?…]+%s+", search_from)
    if not s then break end
    candidates[#candidates+1] = e
    search_from = e + 1
  end

  -- Fall back to any word boundary.
  if #candidates == 0 then
    search_from = 1
    while true do
      local s, e = text:find("%s+", search_from)
      if not s then break end
      candidates[#candidates+1] = e
      search_from = e + 1
    end
  end

  if #candidates == 0 then
    return text, ""
  end
  local best = candidates[1]
  for _, boundary in ipairs(candidates) do
    if math.abs(boundary - target) < math.abs(best - target) then best = boundary end
  end
  local left = text:sub(1, best):gsub("%s+$", "")
  local right = text:sub(best + 1):gsub("^%s+", "")
  return left, right
end

local function find_split_pos_by_words(text, words)
  text = tostring(text or "")
  if not words or #words == 0 then return 0 end
  
  local last_end = 1
  for _, w in ipairs(words) do
    local word_text = w[3]
    if word_text and word_text ~= "" then
      local clean_word = word_text:gsub("^%s+", ""):gsub("%s+$", ""):gsub("[%p%s]", ""):lower()
      if clean_word ~= "" then
        local found = false
        local search_pos = last_end
        while search_pos <= #text do
          local s, e = text:find("%S+", search_pos)
          if not s then break end
          local text_word = text:sub(s, e):lower():gsub("[%p%s]", "")
          if text_word:find(clean_word, 1, true) or clean_word:find(text_word, 1, true) then
            last_end = e + 1
            found = true
            break
          end
          search_pos = e + 1
        end
        if not found then
          local s, e = text:find("%S+", last_end)
          if e then last_end = e + 1 end
        end
      end
    end
  end
  return last_end - 1
end

local function update_take_name(item, text)
  local take = r.GetActiveTake(item)
  if not take then return end
  local short = text
  if #short > 40 then short = short:sub(1, 40) .. "..." end
  r.GetSetMediaItemTakeInfo_String(take, "P_NAME", short, true)
end

local function collect_targets(cursor)
  local selected = {}
  local selected_groups = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    local item = r.GetSelectedMediaItem(0, i)
    selected[item] = true
    local group_id = r.GetMediaItemInfo_Value(item, "I_GROUPID")
    if group_id > 0 then selected_groups[group_id] = true end
  end

  local targets = {}
  for t = 0, r.CountTracks(0) - 1 do
    local track = r.GetTrack(0, t)
    for i = 0, r.CountTrackMediaItems(track) - 1 do
      local item = r.GetTrackMediaItem(track, i)
      local group_id = r.GetMediaItemInfo_Value(item, "I_GROUPID")
      if selected[item] or selected_groups[group_id] then
        local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_end = pos + r.GetMediaItemInfo_Value(item, "D_LENGTH")
        if cursor > pos + EPSILON and cursor < item_end - EPSILON then
          targets[#targets+1] = {
            item = item,
            pos = pos,
            item_end = item_end,
            group_id = group_id,
            phrase_id = montage_model.get_phrase_id(item),
            notes = get_string(item, "P_NOTES"),
            words = (not r.GetActiveTake(item))
              and subtitle_model.get_relative_words(item, false) or {},
          }
        end
      end
    end
  end
  return targets
end

local function next_group_ids(count)
  local max_group = 0
  for t = 0, r.CountTracks(0) - 1 do
    local track = r.GetTrack(0, t)
    for i = 0, r.CountTrackMediaItems(track) - 1 do
      max_group = math.max(
        max_group,
        r.GetMediaItemInfo_Value(r.GetTrackMediaItem(track, i), "I_GROUPID"))
    end
  end
  local ids = {}
  for i = 1, count do ids[i] = max_group + i end
  return ids
end

local function main()
  if r.CountSelectedMediaItems(0) == 0 then
    r.ShowMessageBox(
      "Select an audio or subtitle item, place the edit cursor inside it, and run Smart Split.",
      "ReaTitles Smart Split", 0)
    return
  end

  local cursor = r.GetCursorPosition()
  local targets = collect_targets(cursor)
  if #targets == 0 then
    r.ShowMessageBox(
      "The edit cursor does not cross any selected/grouped item.",
      "ReaTitles Smart Split", 0)
    return
  end

  local group_map = {}
  local group_count = 0
  for _, target in ipairs(targets) do
    if target.group_id > 0 and not group_map[target.group_id] then
      group_count = group_count + 1
      group_map[target.group_id] = group_count
    end
  end
  local ids = next_group_ids(group_count * 2)
  for old_group, index in pairs(group_map) do
    group_map[old_group] = {
      left = ids[(index - 1) * 2 + 1],
      right = ids[(index - 1) * 2 + 2],
      left_phrase = montage_model.new_phrase_id(),
      right_phrase = montage_model.new_phrase_id(),
    }
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local ok, err = xpcall(function()
    r.Main_OnCommand(40289, 0) -- Unselect all items
    for _, target in ipairs(targets) do
      if r.ValidatePtr(target.item, "MediaItem*") then
        local right = r.SplitMediaItem(target.item, cursor)
        if right then
          local groups = group_map[target.group_id]
          if groups then
            r.SetMediaItemInfo_Value(target.item, "I_GROUPID", groups.left)
            r.SetMediaItemInfo_Value(right, "I_GROUPID", groups.right)
            if target.phrase_id ~= "" then
              montage_model.set_phrase_id(target.item, groups.left_phrase)
              montage_model.set_phrase_id(right, groups.right_phrase)
            end
          end

          if target.notes ~= "" or #target.words > 0 then
            local left_text, right_text
            if #target.words > 0 then
              local cut_offset = cursor - target.pos
              local item_length = target.item_end - target.pos
              local left_words = subtitle_model.words_for_range(
                target.words, 0, cut_offset, 0)
              local right_words = subtitle_model.words_for_range(
                target.words, cut_offset, item_length, cut_offset)
              local split_pos = find_split_pos_by_words(target.notes, left_words)
              if split_pos > 0 then
                left_text = target.notes:sub(1, split_pos):gsub("%s+$", "")
                right_text = target.notes:sub(split_pos + 1):gsub("^%s+", "")
              else
                left_text = ""
                right_text = target.notes:gsub("^%s+", "")
              end
              subtitle_model.set_relative_words(target.item, left_words)
              subtitle_model.set_relative_words(right, right_words)
            else
              local ratio = (cursor - target.pos) / (target.item_end - target.pos)
              left_text, right_text = fallback_split_text(target.notes, ratio)
            end

            set_string(target.item, "P_NOTES", left_text)
            set_string(right, "P_NOTES", right_text)
            update_take_name(target.item, left_text)
            update_take_name(right, right_text)
          end
          r.SetMediaItemSelected(right, true)
        end
      end
    end
  end, debug.traceback)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("ReaTitles: Smart Split", -1)

  if not ok then
    r.ShowMessageBox(tostring(err), "ReaTitles Smart Split", 0)
  else
    montage_model.reconcile_project(subtitle_model)
  end
end

main()
