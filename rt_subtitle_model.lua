-- Shared subtitle data model for ReaTitles.
--
-- P_NOTES is always the authoritative phrase text.
-- Word timing is auxiliary data used only by explicit split/repair operations.
-- New timing rows are relative to the subtitle item's left edge so moving an
-- item (including REAPER Ripple Edit) never invalidates them.

local M = {}

M.NOTES_KEY = "P_NOTES"
M.RELATIVE_TIMING_KEY = "P_EXT:REATITLES_WORD_TIMING_REL"
M.LEGACY_TIMING_KEY = "P_EXT:REATITLES_WORD_TIMING"
M.TIMING_ANCHOR_KEY = "P_EXT:REATITLES_TIMING_ANCHOR"
M.TIMING_LENGTH_KEY = "P_EXT:REATITLES_TIMING_LENGTH"
M.EPSILON = 0.000001

function M.get_string(item, key)
  local _, value = reaper.GetSetMediaItemInfo_String(item, key, "", false)
  return value or ""
end

function M.set_string(item, key, value)
  reaper.GetSetMediaItemInfo_String(item, key, value or "", true)
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

return M
