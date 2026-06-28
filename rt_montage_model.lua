-- ReaTitles montage model.
--
-- Audio is the editing truth. Whisper words are stored in source-media time
-- on every managed audio item, so native REAPER Split/trim/Ripple operations
-- can be reconciled without relying on inherited I_GROUPID values.
--
-- Subtitle items are a projection. P_NOTES remains the displayed/manual text,
-- but geometry, generated clones and temporary REAPER groups are maintained
-- from the audio fragments that still contain recognized words.

local M = {}
local r = reaper

M.PHRASE_ID_KEY = "P_EXT:REATITLES_PHRASE_ID"
M.MANAGED_AUDIO_KEY = "P_EXT:REATITLES_MANAGED_AUDIO"
M.GENERATED_SUBTITLE_KEY = "P_EXT:REATITLES_GENERATED_SUBTITLE"
M.SOURCE_WORDS_KEY = "P_EXT:REATITLES_SOURCE_WORDS"
M.WORD_SIGNATURE_KEY = "P_EXT:REATITLES_WORD_SIGNATURE"
M.MANUAL_TEXT_KEY = "P_EXT:REATITLES_MANUAL_TEXT"
M.REVIEW_KEY = "P_EXT:REATITLES_REVIEW"

M.SUBTITLE_TRACK_NAME = "Subtitles"
M.CLUSTER_GAP = 0.45
M.ACTIVE_COVERAGE = 0.65
M.REVIEW_COVERAGE = 0.35
M.EPSILON = 0.000001

local function take_markers_visible()
  return r.GetExtState("ReaTitles", "take_markers_visible") ~= "0"
end

local function get_string(item, key)
  local _, value = r.GetSetMediaItemInfo_String(item, key, "", false)
  return value or ""
end

local function set_string(item, key, value)
  r.GetSetMediaItemInfo_String(item, key, value or "", true)
end

local function set_string_if_changed(item, key, value, change)
  value = value or ""
  if get_string(item, key) == value then return false end
  change()
  set_string(item, key, value)
  return true
end

local function clean_id(value)
  return tostring(value or ""):gsub("[{}%-]", "")
end

local function new_id()
  if r.genGuid then return clean_id(r.genGuid()) end
  return string.format("%08x%08x", os.time(), math.random(0, 0x7fffffff))
end

function M.new_phrase_id()
  return new_id()
end

function M.get_phrase_id(item)
  return item and get_string(item, M.PHRASE_ID_KEY) or ""
end

function M.set_phrase_id(item, phrase_id)
  if item then set_string(item, M.PHRASE_ID_KEY, phrase_id or "") end
end

local function sanitize_text(text)
  return tostring(text or ""):gsub("[\r\n\t]", " ")
end

function M.serialize_source_words(words)
  local rows = {}
  for _, word in ipairs(words or {}) do
    local word_start = tonumber(word[1])
    local word_end = tonumber(word[2])
    if word_start and word_end then
      rows[#rows + 1] = string.format(
        "%.9f\t%.9f\t%s", word_start, word_end, sanitize_text(word[3]))
    end
  end
  return table.concat(rows, "\n")
end

function M.parse_source_words(value)
  local words = {}
  for row in tostring(value or ""):gmatch("[^\r\n]+") do
    local word_start, word_end, text =
      row:match("^([%-%d%.]+)\t([%-%d%.]+)\t(.*)$")
    word_start, word_end = tonumber(word_start), tonumber(word_end)
    if word_start and word_end and text then
      words[#words + 1] = { word_start, word_end, text }
    end
  end
  table.sort(words, function(a, b)
    if a[1] == b[1] then return a[2] < b[2] end
    return a[1] < b[1]
  end)
  return words
end

local function word_key(word)
  return string.format("%.6f:%.6f:%s",
    tonumber(word[1]) or 0, tonumber(word[2]) or 0, tostring(word[3] or ""))
end

function M.word_signature(words)
  local rows = {}
  for _, word in ipairs(words or {}) do rows[#rows + 1] = word_key(word) end
  return table.concat(rows, "|")
end

local function text_from_words(words)
  local parts = {}
  for _, word in ipairs(words or {}) do parts[#parts + 1] = tostring(word[3] or "") end
  return table.concat(parts):gsub("^%s+", ""):gsub("%s+$", "")
end

local function item_bounds(item)
  local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  return pos, pos + r.GetMediaItemInfo_Value(item, "D_LENGTH")
end

local function take_mapping(item)
  local take = r.GetActiveTake(item)
  if not take then return nil end
  local rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if not rate or rate <= 0 then rate = 1 end
  local source_start = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local pos, item_end = item_bounds(item)
  return {
    take = take,
    rate = rate,
    pos = pos,
    item_end = item_end,
    source_start = source_start,
    source_end = source_start + (item_end - pos) * rate,
  }
end

local function source_to_project(mapping, source_time)
  return mapping.pos + (source_time - mapping.source_start) / mapping.rate
end

local function interval_overlap(a_start, a_end, b_start, b_end)
  return math.max(0, math.min(a_end, b_end) - math.max(a_start, b_start))
end

local function merged_coverage(records, word_start, word_end)
  local intervals = {}
  for _, record in ipairs(records) do
    local a = math.max(word_start, record.mapping.source_start)
    local b = math.min(word_end, record.mapping.source_end)
    if b > a + M.EPSILON then intervals[#intervals + 1] = { a, b } end
  end
  table.sort(intervals, function(a, b) return a[1] < b[1] end)
  local total, cur_start, cur_end = 0, nil, nil
  for _, interval in ipairs(intervals) do
    if not cur_start then
      cur_start, cur_end = interval[1], interval[2]
    elseif interval[1] <= cur_end + M.EPSILON then
      cur_end = math.max(cur_end, interval[2])
    else
      total = total + cur_end - cur_start
      cur_start, cur_end = interval[1], interval[2]
    end
  end
  if cur_start then total = total + cur_end - cur_start end
  local duration = math.max(M.EPSILON, word_end - word_start)
  return total / duration
end

local function best_mapping(records, word_start, word_end)
  local midpoint = (word_start + word_end) * 0.5
  local best, best_overlap = nil, -1
  for _, record in ipairs(records) do
    local mapping = record.mapping
    if midpoint >= mapping.source_start - M.EPSILON and
       midpoint <= mapping.source_end + M.EPSILON then
      return mapping
    end
    local overlap = interval_overlap(
      word_start, word_end, mapping.source_start, mapping.source_end)
    if overlap > best_overlap then
      best, best_overlap = mapping, overlap
    end
  end
  return best
end

local function find_subtitle_track()
  for i = 0, r.CountTracks(0) - 1 do
    local track = r.GetTrack(0, i)
    local _, name = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if name == M.SUBTITLE_TRACK_NAME then return track end
  end
  return nil
end

local function collect_all_items()
  local all, max_group = {}, 0
  for ti = 0, r.CountTracks(0) - 1 do
    local track = r.GetTrack(0, ti)
    for i = 0, r.CountTrackMediaItems(track) - 1 do
      local item = r.GetTrackMediaItem(track, i)
      local group_id = r.GetMediaItemInfo_Value(item, "I_GROUPID")
      max_group = math.max(max_group, group_id)
      all[#all + 1] = {
        item = item,
        track = track,
        group_id = group_id,
        has_take = r.GetActiveTake(item) ~= nil,
      }
    end
  end
  return all, max_group
end

function M.register_transcribed_phrase(audio_item, subtitle_item, whisper_words,
                                       source_offset)
  if not audio_item or not subtitle_item then return nil end
  local phrase_id = new_id()
  local words = {}
  source_offset = tonumber(source_offset) or 0
  for _, word in ipairs(whisper_words or {}) do
    local word_start, word_end = tonumber(word[1]), tonumber(word[2])
    if word_start and word_end and type(word[3]) == "string" then
      words[#words + 1] = {
        source_offset + word_start,
        source_offset + word_end,
        word[3],
      }
    end
  end
  set_string(audio_item, M.PHRASE_ID_KEY, phrase_id)
  set_string(audio_item, M.MANAGED_AUDIO_KEY, "1")
  set_string(audio_item, M.SOURCE_WORDS_KEY, M.serialize_source_words(words))
  
  local take = r.GetActiveTake(audio_item)
  if take and take_markers_visible() then
    local num_markers = r.GetNumTakeMarkers(take)
    for i = num_markers - 1, 0, -1 do
      r.DeleteTakeMarker(take, i)
    end
    for _, word in ipairs(words) do
      r.SetTakeMarker(take, -1, word[3], word[1], 0)
    end
  end
  set_string(subtitle_item, M.PHRASE_ID_KEY, phrase_id)
  set_string(subtitle_item, M.GENERATED_SUBTITLE_KEY, "1")
  set_string(subtitle_item, M.WORD_SIGNATURE_KEY, M.word_signature(words))
  set_string(subtitle_item, M.REVIEW_KEY, "")
  return phrase_id
end

function M.mark_manual_text(subtitle_item)
  if not subtitle_item then return end
  set_string(subtitle_item, M.MANUAL_TEXT_KEY, "1")
end

local function text_tokens(text)
  local tokens = {}
  for token in tostring(text or ""):gmatch("%S+") do
    tokens[#tokens + 1] = token
  end
  return tokens
end

local function marker_text(token, old_text, absolute_index)
  local prefix = tostring(old_text or ""):match("^%s*") or ""
  if prefix == "" and absolute_index > 1 then prefix = " " end
  return prefix .. token
end

function M.apply_text_to_audio_item(audio_item, text, subtitle_model)
  if not audio_item or not subtitle_model then return false end
  local take = r.GetActiveTake(audio_item)
  if not take then return false end
  local words = subtitle_model.get_audio_words(take)
  if #words == 0 then
    words = M.parse_source_words(get_string(audio_item, M.SOURCE_WORDS_KEY))
  end
  if #words == 0 then return false end

  local mapping = take_mapping(audio_item)
  if not mapping then return false end
  local first_index, last_index
  for index, word in ipairs(words) do
    local midpoint = (word[1] + word[2]) * 0.5
    if midpoint >= mapping.source_start - M.EPSILON and
       midpoint < mapping.source_end + M.EPSILON then
      first_index = first_index or index
      last_index = index
    end
  end
  if not first_index or not last_index then return false end

  local tokens = text_tokens(text)
  if #tokens == 0 then return false end
  local active_count = last_index - first_index + 1
  local replacement = {}
  if #tokens == active_count then
    for offset, token in ipairs(tokens) do
      local absolute_index = first_index + offset - 1
      local old_word = words[absolute_index]
      replacement[#replacement + 1] = {
        old_word[1],
        old_word[2],
        marker_text(token, old_word[3], absolute_index),
      }
    end
  else
    local range_start = words[first_index][1]
    local range_end = words[last_index][2]
    local duration = math.max(0.001, range_end - range_start)
    local total_weight = 0
    for _, token in ipairs(tokens) do
      total_weight = total_weight + math.max(1, #token)
    end
    local cursor = range_start
    for offset, token in ipairs(tokens) do
      local weight = math.max(1, #token)
      local word_end
      if offset == #tokens then
        word_end = range_end
      else
        word_end = cursor + duration * weight / total_weight
      end
      replacement[#replacement + 1] = {
        cursor,
        word_end,
        marker_text(token, nil, first_index + offset - 1),
      }
      cursor = word_end
    end
  end

  local updated = {}
  for index = 1, first_index - 1 do updated[#updated + 1] = words[index] end
  for _, word in ipairs(replacement) do updated[#updated + 1] = word end
  for index = last_index + 1, #words do updated[#updated + 1] = words[index] end

  subtitle_model.set_audio_words(take, updated)
  set_string(audio_item, M.SOURCE_WORDS_KEY, M.serialize_source_words(updated))
  set_string(audio_item, M.MANUAL_TEXT_KEY, "1")
  return true
end

function M.sync_audio_notes_to_words(subtitle_model)
  if not subtitle_model then return 0 end
  local plan = {}
  for ti = 0, r.CountTracks(0) - 1 do
    local track = r.GetTrack(0, ti)
    for i = 0, r.CountTrackMediaItems(track) - 1 do
      local item = r.GetTrackMediaItem(track, i)
      local take = r.GetActiveTake(item)
      local notes = get_string(item, "P_NOTES")
      if take and notes ~= "" and
         get_string(item, M.MANAGED_AUDIO_KEY) == "1" then
        local words = subtitle_model.get_audio_words(take)
        local mapping = take_mapping(item)
        local active_words = {}
        if mapping then
          for _, word in ipairs(words) do
            local midpoint = (word[1] + word[2]) * 0.5
            if midpoint >= mapping.source_start - M.EPSILON and
               midpoint < mapping.source_end + M.EPSILON then
              active_words[#active_words + 1] = word
            end
          end
        end
        local tokens = text_tokens(notes)
        if #tokens > 0 and #tokens == #active_words then
          local differs = false
          for index, token in ipairs(tokens) do
            local marker_word =
              tostring(active_words[index][3] or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if marker_word ~= token then
              differs = true
              break
            end
          end
          if differs then plan[#plan + 1] = { item = item, text = notes } end
        end
      end
    end
  end
  if #plan == 0 then return 0 end
  r.Undo_BeginBlock()
  for _, entry in ipairs(plan) do
    M.apply_text_to_audio_item(entry.item, entry.text, subtitle_model)
  end
  r.UpdateArrange()
  r.Undo_EndBlock("ReaTitles: Synchronize edited text with word markers", -1)
  return #plan
end

local function migrate_group_pairs(all_items, subtitle_track, subtitle_model,
                                   change)
  local groups = {}
  for _, entry in ipairs(all_items) do
    if entry.group_id > 0 then
      local group = groups[entry.group_id]
      if not group then
        group = { audio = {}, subtitles = {} }
        groups[entry.group_id] = group
      end
      if entry.has_take then
        group.audio[#group.audio + 1] = entry.item
      elseif entry.track == subtitle_track then
        group.subtitles[#group.subtitles + 1] = entry.item
      end
    end
  end

  local migrated = 0
  for _, group in pairs(groups) do
    if #group.audio > 0 and #group.subtitles > 0 then
      local phrase_id = ""
      for _, item in ipairs(group.audio) do
        phrase_id = get_string(item, M.PHRASE_ID_KEY)
        if phrase_id ~= "" then break end
      end
      if phrase_id == "" then
        for _, item in ipairs(group.subtitles) do
          phrase_id = get_string(item, M.PHRASE_ID_KEY)
          if phrase_id ~= "" then break end
        end
      end
      local needs_migration = phrase_id == ""
      if needs_migration then phrase_id = new_id() end

      local source_words = {}
      for _, item in ipairs(group.audio) do
        source_words = M.parse_source_words(get_string(item, M.SOURCE_WORDS_KEY))
        if #source_words > 0 then break end
      end

      if #source_words == 0 and subtitle_model then
        table.sort(group.subtitles, function(a, b)
          local ap = r.GetMediaItemInfo_Value(a, "D_POSITION")
          local bp = r.GetMediaItemInfo_Value(b, "D_POSITION")
          return ap < bp
        end)
        local canonical = group.subtitles[1]
        local relative_words = subtitle_model.get_relative_words(canonical, false)
        local sub_pos = r.GetMediaItemInfo_Value(canonical, "D_POSITION")
        for _, word in ipairs(relative_words or {}) do
          local project_start = sub_pos + word[1]
          local project_end = sub_pos + word[2]
          local midpoint = (project_start + project_end) * 0.5
          local chosen = nil
          for _, audio_item in ipairs(group.audio) do
            local mapping = take_mapping(audio_item)
            if mapping and midpoint >= mapping.pos - M.EPSILON and
               midpoint <= mapping.item_end + M.EPSILON then
              chosen = mapping
              break
            end
          end
          if chosen then
            source_words[#source_words + 1] = {
              chosen.source_start + (project_start - chosen.pos) * chosen.rate,
              chosen.source_start + (project_end - chosen.pos) * chosen.rate,
              word[3],
            }
          end
        end
      end

      local serialized = M.serialize_source_words(source_words)
      for _, item in ipairs(group.audio) do
        set_string_if_changed(item, M.PHRASE_ID_KEY, phrase_id, change)
        set_string_if_changed(item, M.MANAGED_AUDIO_KEY, "1", change)
        if serialized ~= "" then
          set_string_if_changed(item, M.SOURCE_WORDS_KEY, serialized, change)
        end
      end
      for _, item in ipairs(group.subtitles) do
        set_string_if_changed(item, M.PHRASE_ID_KEY, phrase_id, change)
        set_string_if_changed(item, M.GENERATED_SUBTITLE_KEY, "1", change)
      end
      if needs_migration then migrated = migrated + 1 end
    end
  end
  return migrated
end

local function build_clusters(records, words)
  local candidates = {}
  if #words > 0 then
    for _, record in ipairs(records) do
      local contains_word = false
      for _, word in ipairs(words) do
        if interval_overlap(
          word[1], word[2],
          record.mapping.source_start, record.mapping.source_end) > M.EPSILON then
          contains_word = true
          break
        end
      end
      if contains_word then candidates[#candidates + 1] = record end
    end
  else
    for _, record in ipairs(records) do candidates[#candidates + 1] = record end
  end

  table.sort(candidates, function(a, b)
    if a.mapping.pos == b.mapping.pos then
      return a.mapping.item_end < b.mapping.item_end
    end
    return a.mapping.pos < b.mapping.pos
  end)

  local raw_clusters = {}
  for _, record in ipairs(candidates) do
    local cluster = raw_clusters[#raw_clusters]
    if not cluster or record.mapping.pos > cluster.timeline_end + M.CLUSTER_GAP then
      cluster = { records = {}, timeline_end = record.mapping.item_end }
      raw_clusters[#raw_clusters + 1] = cluster
    end
    cluster.records[#cluster.records + 1] = record
    cluster.timeline_end = math.max(cluster.timeline_end, record.mapping.item_end)
  end

  local clusters = {}
  for _, raw in ipairs(raw_clusters) do
    local active_words, mapped_words, ambiguous = {}, {}, false
    if #words > 0 then
      for _, word in ipairs(words) do
        local coverage = merged_coverage(raw.records, word[1], word[2])
        if coverage >= M.ACTIVE_COVERAGE then
          local mapping = best_mapping(raw.records, word[1], word[2])
          if mapping then
            active_words[#active_words + 1] = word
            mapped_words[#mapped_words + 1] = {
              source_to_project(mapping, word[1]),
              source_to_project(mapping, word[2]),
              word[3],
              source_word = word,
            }
          end
        elseif coverage >= M.REVIEW_COVERAGE then
          ambiguous = true
        end
      end
      table.sort(mapped_words, function(a, b)
        if a[1] == b[1] then return a[2] < b[2] end
        return a[1] < b[1]
      end)
    end

    if #words == 0 or #active_words > 0 then
      local supporting = {}
      for _, record in ipairs(raw.records) do
        local supports = #words == 0
        if not supports then
          for _, word in ipairs(active_words) do
            if interval_overlap(
              word[1], word[2],
              record.mapping.source_start, record.mapping.source_end) > M.EPSILON then
              supports = true
              break
            end
          end
        end
        if supports then supporting[#supporting + 1] = record end
      end
      if #supporting > 0 then
        local start_pos, end_pos = math.huge, -math.huge
        for _, record in ipairs(supporting) do
          start_pos = math.min(start_pos, record.mapping.pos)
          end_pos = math.max(end_pos, record.mapping.item_end)
        end
        clusters[#clusters + 1] = {
          records = supporting,
          start_pos = start_pos,
          end_pos = end_pos,
          source_words = active_words,
          mapped_words = mapped_words,
          signature = M.word_signature(active_words),
          text = text_from_words(mapped_words),
          ambiguous = ambiguous,
        }
      end
    end
  end
  return clusters
end

local function choose_subtitle(cluster, subtitles, used)
  local best, best_score = nil, math.huge
  for _, item in ipairs(subtitles) do
    if not used[item] and r.ValidatePtr(item, "MediaItem*") then
      local pos, item_end = item_bounds(item)
      local overlap = interval_overlap(
        cluster.start_pos, cluster.end_pos, pos, item_end)
      local score = math.abs(pos - cluster.start_pos) - overlap * 10
      if score < best_score then best, best_score = item, score end
    end
  end
  return best
end

local function set_number_if_changed(item, key, value, change, tolerance)
  local current = r.GetMediaItemInfo_Value(item, key)
  if math.abs(current - value) <= (tolerance or M.EPSILON) then return false end
  change()
  r.SetMediaItemInfo_Value(item, key, value)
  return true
end

function M.reconcile_project(subtitle_model)
  local subtitle_track = find_subtitle_track()
  if not subtitle_track then return false, { reason = "no_subtitle_track" } end

  local undo_open, changed = false, false
  local function change()
    if not undo_open then
      r.Undo_BeginBlock()
      r.PreventUIRefresh(1)
      undo_open = true
    end
    changed = true
  end

  local stats = {
    migrated = 0,
    created = 0,
    deleted = 0,
    repaired_groups = 0,
    review = 0,
  }

  local ok, err = xpcall(function()
    local all_items, max_group = collect_all_items()
    stats.migrated = migrate_group_pairs(
      all_items, subtitle_track, subtitle_model, change)

    -- Migration can add metadata without changing pointers, so reuse the list.
    local phrases = {}
    local group_counts = {}
    for _, entry in ipairs(all_items) do
      if entry.group_id > 0 then
        group_counts[entry.group_id] = (group_counts[entry.group_id] or 0) + 1
      end
      local phrase_id = get_string(entry.item, M.PHRASE_ID_KEY)
      if phrase_id ~= "" then
        local phrase = phrases[phrase_id]
        if not phrase then
          phrase = {
            audio = {},
            subtitles = {},
            words = {},
            color = 0,
            manual_text = false,
          }
          phrases[phrase_id] = phrase
        end
        if entry.has_take and
           get_string(entry.item, M.MANAGED_AUDIO_KEY) == "1" then
          local mapping = take_mapping(entry.item)
          if mapping then
            local words = M.parse_source_words(
              get_string(entry.item, M.SOURCE_WORDS_KEY))
            if #phrase.words == 0 and #words > 0 then phrase.words = words end
            phrase.audio[#phrase.audio + 1] = {
              item = entry.item,
              mapping = mapping,
              group_id = entry.group_id,
            }
          end
        elseif entry.track == subtitle_track and
               get_string(entry.item, M.GENERATED_SUBTITLE_KEY) == "1" then
          phrase.subtitles[#phrase.subtitles + 1] = entry.item
          local color = r.GetMediaItemInfo_Value(entry.item, "I_CUSTOMCOLOR")
          if phrase.color == 0 and color ~= 0 then phrase.color = color end
          if get_string(entry.item, M.MANUAL_TEXT_KEY) == "1" then
            phrase.manual_text = true
          end
        end
      end
    end

    for phrase_id, phrase in pairs(phrases) do
      local clusters = build_clusters(phrase.audio, phrase.words)
      local used, desired_audio = {}, {}
      table.sort(phrase.subtitles, function(a, b)
        return r.GetMediaItemInfo_Value(a, "D_POSITION") <
               r.GetMediaItemInfo_Value(b, "D_POSITION")
      end)

      for _, cluster in ipairs(clusters) do
        local sub_item = choose_subtitle(cluster, phrase.subtitles, used)
        if not sub_item then
          change()
          sub_item = r.AddMediaItemToTrack(subtitle_track)
          r.SetMediaItemInfo_Value(sub_item, "C_LANEDISP", 3)
          if phrase.color ~= 0 then
            r.SetMediaItemInfo_Value(sub_item, "I_CUSTOMCOLOR", phrase.color)
          end
          set_string(sub_item, M.PHRASE_ID_KEY, phrase_id)
          set_string(sub_item, M.GENERATED_SUBTITLE_KEY, "1")
          if phrase.manual_text then
            set_string(sub_item, M.MANUAL_TEXT_KEY, "1")
          end
          stats.created = stats.created + 1
        end
        used[sub_item] = true

        local old_signature = get_string(sub_item, M.WORD_SIGNATURE_KEY)
        local old_notes = get_string(sub_item, "P_NOTES")
        local signature_changed =
          old_signature ~= "" and old_signature ~= cluster.signature
        local desired_text = old_notes
        if cluster.text ~= "" then
          if old_notes == "" or
             signature_changed then
            desired_text = cluster.text
          end
        end
        set_string_if_changed(sub_item, "P_NOTES", desired_text, change)
        set_string_if_changed(
          sub_item, M.PHRASE_ID_KEY, phrase_id, change)
        set_string_if_changed(
          sub_item, M.GENERATED_SUBTITLE_KEY, "1", change)
        set_string_if_changed(
          sub_item, M.WORD_SIGNATURE_KEY, cluster.signature, change)
        local review = ""
        if cluster.ambiguous then
          review = "PARTIAL_WORD"
        elseif phrase.manual_text and signature_changed then
          review = "MANUAL_TEXT_REMAP"
        end
        set_string_if_changed(sub_item, M.REVIEW_KEY, review, change)
        if review ~= "" then stats.review = stats.review + 1 end

        set_number_if_changed(
          sub_item, "D_POSITION", cluster.start_pos, change, 0.00001)
        set_number_if_changed(
          sub_item, "D_LENGTH",
          math.max(0.01, cluster.end_pos - cluster.start_pos), change, 0.00001)

        local cluster_color =
          r.GetMediaItemInfo_Value(sub_item, "I_CUSTOMCOLOR")
        if cluster_color == 0 then cluster_color = phrase.color end

        if subtitle_model and #cluster.mapped_words > 0 then
          local relative = {}
          for _, word in ipairs(cluster.mapped_words) do
            relative[#relative + 1] = {
              word[1] - cluster.start_pos,
              word[2] - cluster.start_pos,
              word[3],
            }
          end
          local serialized = subtitle_model.serialize_words(relative)
          if get_string(sub_item, subtitle_model.RELATIVE_TIMING_KEY) ~= serialized then
            change()
            subtitle_model.set_relative_words(sub_item, relative)
          end
        end

        local members = { [sub_item] = true }
        local reusable_group = r.GetMediaItemInfo_Value(sub_item, "I_GROUPID")
        for _, record in ipairs(cluster.records) do
          members[record.item] = true
          desired_audio[record.item] = true
          if reusable_group <= 0 or record.group_id ~= reusable_group then
            reusable_group = 0
          end
        end
        if reusable_group > 0 and
           group_counts[reusable_group] ~= #cluster.records + 1 then
          reusable_group = 0
        end
        local group_id = reusable_group
        if group_id <= 0 then
          max_group = max_group + 1
          group_id = max_group
          stats.repaired_groups = stats.repaired_groups + 1
        end
        set_number_if_changed(sub_item, "I_GROUPID", group_id, change)
        for _, record in ipairs(cluster.records) do
          set_number_if_changed(record.item, "I_GROUPID", group_id, change)
          if cluster_color ~= 0 then
            set_number_if_changed(
              record.item, "I_CUSTOMCOLOR", cluster_color, change)
          end
        end
      end

      for _, record in ipairs(phrase.audio) do
        if not desired_audio[record.item] then
          set_number_if_changed(record.item, "I_GROUPID", 0, change)
        end
      end
      for _, sub_item in ipairs(phrase.subtitles) do
        if not used[sub_item] and r.ValidatePtr(sub_item, "MediaItem*") then
          change()
          r.DeleteTrackMediaItem(subtitle_track, sub_item)
          stats.deleted = stats.deleted + 1
        end
      end
    end
  end, debug.traceback)

  if undo_open then
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
    r.Undo_EndBlock("ReaTitles: Synchronize montage subtitles", -1)
  end
  if not ok then return changed, stats, err end
  return changed, stats
end

function M.rebuild_take_markers(audio_item, subtitle_model)
  local take = r.GetActiveTake(audio_item)
  if not take then return false end
  
  local words_str = get_string(audio_item, M.SOURCE_WORDS_KEY)
  local words = {}
  
  if words_str ~= "" then
    words = M.parse_source_words(words_str)
  else
    -- Try to migrate from grouped subtitle item!
    local group_id = r.GetMediaItemInfo_Value(audio_item, "I_GROUPID")
    if group_id > 0 and subtitle_model then
      -- Find grouped subtitle item
      local sub_item = nil
      for i = 0, r.CountTracks(0) - 1 do
        local tr = r.GetTrack(0, i)
        local _, name = r.GetTrackName(tr)
        if name == M.SUBTITLE_TRACK_NAME then
          for j = 0, r.CountTrackMediaItems(tr) - 1 do
            local item = r.GetTrackMediaItem(tr, j)
            if r.GetMediaItemInfo_Value(item, "I_GROUPID") == group_id then
              sub_item = item
              break
            end
          end
          break
        end
      end
      
      if sub_item then
        local sub_words = subtitle_model.get_relative_words(sub_item, true)
        if #sub_words > 0 then
          local audio_pos = r.GetMediaItemInfo_Value(audio_item, "D_POSITION")
          local sub_pos = r.GetMediaItemInfo_Value(sub_item, "D_POSITION")
          local start_offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
          local playrate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
          if playrate <= 0 then playrate = 1 end
          
          for _, sw in ipairs(sub_words) do
            local tl_start = sub_pos + sw[1]
            local tl_end = sub_pos + sw[2]
            local src_start = start_offs + (tl_start - audio_pos) * playrate
            local src_end = start_offs + (tl_end - audio_pos) * playrate
            table.insert(words, { src_start, src_end, sw[3] })
          end
          
          -- Save to audio item
          set_string(audio_item, M.SOURCE_WORDS_KEY, M.serialize_source_words(words))
          set_string(audio_item, M.MANAGED_AUDIO_KEY, "1")
          -- Set phrase ID if not set
          local phrase_id = get_string(audio_item, M.PHRASE_ID_KEY)
          if phrase_id == "" then
            phrase_id = get_string(sub_item, M.PHRASE_ID_KEY)
            if phrase_id == "" then phrase_id = M.new_phrase_id() end
            set_string(audio_item, M.PHRASE_ID_KEY, phrase_id)
            set_string(sub_item, M.PHRASE_ID_KEY, phrase_id)
          end
        end
      end
    end
  end
  
  if #words == 0 then return false end
  
  local markers_visible = not subtitle_model or
    subtitle_model.take_markers_visible()
  if markers_visible then
    local num_markers = r.GetNumTakeMarkers(take)
    for i = num_markers - 1, 0, -1 do
      r.DeleteTakeMarker(take, i)
    end
  end
  local snapped_words = {}
  local prev_end = 0
  for _, word in ipairs(words) do
    local snapped = subtitle_model and subtitle_model.snap_word_to_onset(take, word[1], prev_end) or word[1]
    if markers_visible then
      r.SetTakeMarker(take, -1, word[3], snapped, 0)
    end
    local w_end = word[2]
    if w_end < snapped then w_end = snapped + 0.1 end
    table.insert(snapped_words, { snapped, w_end, word[3] })
    prev_end = snapped
  end
  set_string(audio_item, M.SOURCE_WORDS_KEY, M.serialize_source_words(snapped_words))
  return true
end

function M.set_take_markers_visible(visible, subtitle_model)
  if not subtitle_model then return 0 end
  subtitle_model.set_take_markers_visible(visible)
  local affected = 0
  for ti = 0, r.CountTracks(0) - 1 do
    local track = r.GetTrack(0, ti)
    for i = 0, r.CountTrackMediaItems(track) - 1 do
      local item = r.GetTrackMediaItem(track, i)
      local take = r.GetActiveTake(item)
      if take and (
          get_string(item, M.MANAGED_AUDIO_KEY) == "1" or
          get_string(item, M.SOURCE_WORDS_KEY) ~= "" or
          subtitle_model.get_take_string(
            take, subtitle_model.HIDDEN_TAKE_MARKERS_KEY) ~= "") then
        if visible then
          local restored = subtitle_model.show_take_markers(take)
          if restored == 0 then
            M.rebuild_take_markers(item, subtitle_model)
          end
        else
          subtitle_model.hide_take_markers(take)
        end
        affected = affected + 1
      end
    end
  end
  r.UpdateArrange()
  return affected
end

return M
