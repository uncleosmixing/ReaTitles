-- Shared subtitle data model for ReaTitles.
--
-- P_NOTES is the displayed phrase text and remains authoritative while the
-- active source-word signature is unchanged. rt_montage_model.lua may rebuild
-- it when an audio edit actually removes or separates spoken words.
-- Word timing is auxiliary data used by split/repair/montage operations.
-- New timing rows are relative to the subtitle item's left edge so moving an
-- item (including REAPER Ripple Edit) never invalidates them.

local M = {}

M.NOTES_KEY = "P_NOTES"
M.RELATIVE_TIMING_KEY = "P_EXT:REATITLES_WORD_TIMING_REL"
M.LEGACY_TIMING_KEY = "P_EXT:REATITLES_WORD_TIMING"
M.TIMING_ANCHOR_KEY = "P_EXT:REATITLES_TIMING_ANCHOR"
M.TIMING_LENGTH_KEY = "P_EXT:REATITLES_TIMING_LENGTH"
M.AUDIO_WORDS_KEY = "P_EXT:REATITLES_AUDIO_WORDS"
M.EPSILON = 0.000001

function M.get_string(item, key)
  local _, value = reaper.GetSetMediaItemInfo_String(item, key, "", false)
  return value or ""
end

function M.set_string(item, key, value)
  reaper.GetSetMediaItemInfo_String(item, key, value or "", true)
end

function M.get_take_string(take, key)
  local _, value = reaper.GetSetMediaItemTakeInfo_String(take, key, "", false)
  return value or ""
end

function M.set_take_string(take, key, value)
  reaper.GetSetMediaItemTakeInfo_String(take, key, value or "", true)
end

function M.parse_words(metadata)
  local words = {}
  for row in (metadata or ""):gmatch("[^\r\n]+") do
    local start_pos, end_pos, text =
      row:match("^([%-%d%.]+)\t([%-%d%.]+)\t(.*)$")
    start_pos, end_pos = tonumber(start_pos), tonumber(end_pos)
    if start_pos and end_pos and text then
      words[#words + 1] = { start_pos, end_pos, text }
    end
  end
  table.sort(words, function(a, b)
    if a[1] == b[1] then return a[2] < b[2] end
    return a[1] < b[1]
  end)
  return words
end

function M.serialize_words(words)
  local rows = {}
  for _, word in ipairs(words or {}) do
    local start_pos, end_pos, text =
      tonumber(word[1]), tonumber(word[2]), tostring(word[3] or "")
    if start_pos and end_pos then
      text = text:gsub("[\r\n\t]", " ")
      rows[#rows + 1] = string.format(
        "%.9f\t%.9f\t%s", start_pos, end_pos, text)
    end
  end
  return table.concat(rows, "\n")
end

function M.set_relative_words(item, words)
  M.set_string(item, M.RELATIVE_TIMING_KEY, M.serialize_words(words))
  -- Remove movement-sensitive legacy state after successful migration.
  M.set_string(item, M.LEGACY_TIMING_KEY, "")
  M.set_string(item, M.TIMING_ANCHOR_KEY, "")
  M.set_string(item, M.TIMING_LENGTH_KEY, "")
end

function M.get_relative_words(item, migrate_legacy)
  local relative = M.get_string(item, M.RELATIVE_TIMING_KEY)
  if relative ~= "" then return M.parse_words(relative), false end

  local legacy = M.get_string(item, M.LEGACY_TIMING_KEY)
  if legacy == "" then return {}, false end

  local absolute_words = M.parse_words(legacy)
  local anchor = tonumber(M.get_string(item, M.TIMING_ANCHOR_KEY))
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_end = item_pos + item_length
  local overlapping = {}
  for _, word in ipairs(absolute_words) do
    local midpoint = (word[1] + word[2]) * 0.5
    if midpoint >= item_pos - M.EPSILON and
       midpoint < item_end - M.EPSILON then
      overlapping[#overlapping + 1] = word
    end
  end

  -- Unmoved legacy items and native split children can be converted exactly
  -- from their current project range. If an old item has already moved, use its
  -- saved anchor; very old projects without anchors align the first word to 0.
  local source_words = (#overlapping > 0) and overlapping or absolute_words
  local base
  if #overlapping > 0 then
    base = item_pos
  elseif anchor then
    base = anchor
  elseif absolute_words[1] then
    base = absolute_words[1][1]
  else
    base = item_pos
  end
  local words = {}
  for _, word in ipairs(source_words) do
    words[#words + 1] = {
      word[1] - base,
      word[2] - base,
      word[3],
    }
  end
  if migrate_legacy and #words > 0 then M.set_relative_words(item, words) end
  return words, true
end

function M.words_for_range(words, range_start, range_end, rebase)
  local selected = {}
  for _, word in ipairs(words or {}) do
    local midpoint = (word[1] + word[2]) * 0.5
    if midpoint >= range_start - M.EPSILON and
       midpoint < range_end - M.EPSILON then
      selected[#selected + 1] = {
        word[1] - (rebase or 0),
        word[2] - (rebase or 0),
        word[3],
      }
    end
  end
  return selected
end

function M.text_from_words(words)
  local parts = {}
  for _, word in ipairs(words or {}) do
    parts[#parts + 1] = tostring(word[3] or "")
  end
  return table.concat(parts):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.text_for_range(words, range_start, range_end)
  return M.text_from_words(
    M.words_for_range(words, range_start, range_end, 0))
end

function M.snap_word_to_onset(take, w_start, prev_end_time)
  local function log_debug(msg)
    local f = io.open("c:\\Users\\uncle\\Desktop\\Development\\Development\\ReaTitles\\rt_sync.log", "a")
    if f then
      f:write(msg .. "\n")
      f:close()
    end
    reaper.ShowConsoleMsg(msg .. "\n")
  end

  -- Determine search range
  local search_start = w_start - 0.40
  if not prev_end_time or prev_end_time == 0 then
    search_start = w_start - 0.60
  else
    if search_start < prev_end_time then
      search_start = prev_end_time
    end
  end
  if search_start < 0 then search_start = 0 end
  
  local search_end = w_start + 0.30
  local duration = search_end - search_start
  if duration <= 0.005 then 
    log_debug(string.format("[Onset Sync] w_start: %.3f - skipped (duration too small)", w_start))
    return w_start 
  end
  
  local peakrate = 250 -- 4ms resolution
  local numsamples = math.floor(duration * peakrate)
  if numsamples < 5 then 
    log_debug(string.format("[Onset Sync] w_start: %.3f - skipped (samples count too small: %d)", w_start, numsamples))
    return w_start 
  end
  
  local numchannels = 1
  local want_extra_type = 0
  local peaks = reaper.new_array(numchannels * numsamples * 2)
  
  local retval = reaper.GetMediaItemTake_Peaks(
    take, peakrate, search_start, numchannels, numsamples, want_extra_type, peaks
  )
  
  if retval <= 0 then 
    log_debug(string.format("[Onset Sync] w_start: %.3f - GetPeaks failed (%d)", w_start, retval))
    return w_start 
  end
  
  local actual_samples = retval % 1048576
  if actual_samples > numsamples then
    actual_samples = numsamples
  end
  
  local tbl = peaks.table()
  local tbl_len = #tbl
  local safe_samples = math.min(actual_samples, math.floor(tbl_len / 2))
  
  if safe_samples <= 0 then 
    log_debug(string.format("[Onset Sync] w_start: %.3f - safe_samples <= 0", w_start))
    return w_start 
  end
  
  local max_vals = {}
  local global_max = 0
  local global_min = 1
  for idx = 0, safe_samples - 1 do
    local val = math.abs(tbl[idx + 1] or 0)
    max_vals[idx + 1] = val
    if val > global_max then global_max = val end
    if val < global_min then global_min = val end
  end
  
  if global_max < 0.008 then
    log_debug(string.format("[Onset Sync] w_start: %.3f - quiet segment (max: %.4f)", w_start, global_max))
    return w_start
  end
  
  local threshold = global_min + 0.10 * (global_max - global_min)
  threshold = math.max(threshold, 0.008)
  
  local onset_idx = nil
  for idx = 1, safe_samples - 1 do
    if max_vals[idx] >= threshold and max_vals[idx + 1] >= threshold then
      onset_idx = idx
      break
    end
  end
  
  if onset_idx then
    local onset_time = search_start + (onset_idx - 1) / peakrate
    if math.abs(onset_time - w_start) < 0.55 then
      log_debug(string.format("[Onset Sync] w_start: %.3f -> snapped to %.3f (shift: %.3f, max: %.3f, thresh: %.3f)", 
        w_start, onset_time, onset_time - w_start, global_max, threshold))
      return onset_time
    else
      log_debug(string.format("[Onset Sync] w_start: %.3f -> snap candidate %.3f rejected (shift too large)", w_start, onset_time))
    end
  end
  
  log_debug(string.format("[Onset Sync] w_start: %.3f -> no onset found (max: %.3f, thresh: %.3f)", w_start, global_max, threshold))
  return w_start
end

function M.set_audio_words(take, words)
  -- Rebuild take markers and snap times
  local num_markers = reaper.GetNumTakeMarkers(take)
  for i = num_markers - 1, 0, -1 do
    reaper.DeleteTakeMarker(take, i)
  end
  
  local snapped_words = {}
  local prev_end = 0
  for _, word in ipairs(words) do
    local start_time = word[1]
    local snapped = M.snap_word_to_onset(take, start_time, prev_end)
    reaper.SetTakeMarker(take, -1, word[3], snapped, 0)
    
    local w_end = word[2]
    if w_end < snapped then w_end = snapped + 0.1 end
    table.insert(snapped_words, { snapped, w_end, word[3] })
    
    prev_end = snapped
  end
  
  -- Store snapped in take extension state
  M.set_take_string(take, M.AUDIO_WORDS_KEY, M.serialize_words(snapped_words))
end

function M.get_audio_words(take)
  local data = M.get_take_string(take, M.AUDIO_WORDS_KEY)
  if data == "" then return {} end
  return M.parse_words(data)
end

return M
