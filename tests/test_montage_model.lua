local tracks = {
  { name = "Dialogue", items = {} },
  { name = "Subtitles", items = {} },
}
local guid_counter = 0

local function audio(pos, length, source_offset)
  local item = {
    values = {
      D_POSITION = pos,
      D_LENGTH = length,
      I_GROUPID = 1,
      I_CUSTOMCOLOR = 0,
    },
    strings = {},
    take = {
      values = {
        D_PLAYRATE = 1,
        D_STARTOFFS = source_offset,
      },
      strings = {},
      markers = {},
    },
  }
  tracks[1].items[#tracks[1].items + 1] = item
  return item
end

local function subtitle(pos, length, text)
  local item = {
    values = {
      D_POSITION = pos,
      D_LENGTH = length,
      I_GROUPID = 1,
      I_CUSTOMCOLOR = 0,
    },
    strings = { P_NOTES = text },
  }
  tracks[2].items[#tracks[2].items + 1] = item
  return item
end

reaper = {
  CountTracks = function() return #tracks end,
  GetTrack = function(_, index) return tracks[index + 1] end,
  CountTrackMediaItems = function(track) return #track.items end,
  GetTrackMediaItem = function(track, index) return track.items[index + 1] end,
  GetSetMediaTrackInfo_String = function(track, key)
    if key == "P_NAME" then return true, track.name end
    return true, ""
  end,
  GetMediaItemInfo_Value = function(item, key) return item.values[key] or 0 end,
  SetMediaItemInfo_Value = function(item, key, value)
    item.values[key] = value
    return true
  end,
  GetSetMediaItemInfo_String = function(item, key, value, set)
    if set then item.strings[key] = value end
    return true, item.strings[key] or ""
  end,
  GetActiveTake = function(item) return item.take end,
  GetMediaItemTakeInfo_Value = function(take, key) return take.values[key] or 0 end,
  GetSetMediaItemTakeInfo_String = function(take, key, value, set)
    if set then take.strings[key] = value end
    return true, take.strings[key] or ""
  end,
  GetExtState = function(_, key)
    return key == "take_markers_visible" and "1" or ""
  end,
  SetExtState = function() end,
  GetProjExtState = function() return 0, "" end,
  SetProjExtState = function() return 1 end,
  GetNumTakeMarkers = function(take) return #take.markers end,
  GetTakeMarker = function(take, index)
    local marker = take.markers[index + 1]
    if not marker then return -1, "", 0 end
    return marker.pos, marker.name, marker.color
  end,
  SetTakeMarker = function(take, _, name, pos, color)
    take.markers[#take.markers + 1] = {
      name = name,
      pos = pos,
      color = color or 0,
    }
    return #take.markers - 1
  end,
  DeleteTakeMarker = function(take, index)
    table.remove(take.markers, index + 1)
    return true
  end,
  AddMediaItemToTrack = function(track)
    local item = {
      values = {
        D_POSITION = 0,
        D_LENGTH = 1,
        I_GROUPID = 0,
        I_CUSTOMCOLOR = 0,
      },
      strings = {},
    }
    track.items[#track.items + 1] = item
    return item
  end,
  DeleteTrackMediaItem = function(track, item)
    for i, candidate in ipairs(track.items) do
      if candidate == item then table.remove(track.items, i); return true end
    end
    return false
  end,
  ValidatePtr = function(item) return item ~= nil end,
  genGuid = function()
    guid_counter = guid_counter + 1
    return string.format("{00000000-0000-0000-0000-%012d}", guid_counter)
  end,
  Undo_BeginBlock = function() end,
  Undo_EndBlock = function() end,
  PreventUIRefresh = function() end,
  UpdateArrange = function() end,
}

local subtitle_model = dofile("rt_subtitle_model.lua")
local montage_model = dofile("rt_montage_model.lua")

-- Editing a managed audio phrase updates the persistent word map and visible
-- take-marker names while preserving one-to-one word timing.
do
  local edited_item = audio(0, 3, 0)
  local original_words = {
    { 0.1, 0.8, " Первое" },
    { 0.9, 1.6, " виброл" },
    { 1.7, 2.5, " третье" },
  }
  subtitle_model.set_audio_words(edited_item.take, original_words)
  assert(montage_model.apply_text_to_audio_item(
    edited_item, "Первое Vivol третье", subtitle_model))
  local edited_words = subtitle_model.get_audio_words(edited_item.take)
  assert(edited_words[2][1] == 0.9 and edited_words[2][2] == 1.6)
  assert(edited_words[2][3]:find("Vivol", 1, true))
  assert(edited_item.take.markers[2].name:find("Vivol", 1, true))
end

-- Hiding take markers preserves exact position, name and color, then restores
-- them without transcription or word-map changes.
do
  local marker_item = audio(0, 2, 0)
  marker_item.take.markers = {
    { pos = 0.25, name = "word\tone", color = 123 },
    { pos = 1.50, name = "word two", color = 456 },
  }
  assert(subtitle_model.hide_take_markers(marker_item.take) == 2)
  assert(#marker_item.take.markers == 0)
  assert(subtitle_model.show_take_markers(marker_item.take) == 2)
  assert(#marker_item.take.markers == 2)
  assert(marker_item.take.markers[1].pos == 0.25)
  assert(marker_item.take.markers[1].name == "word\tone")
  assert(marker_item.take.markers[1].color == 123)
end

local function reset()
  tracks[1].items = {}
  tracks[2].items = {}
end

-- Text edited before marker synchronization was introduced is repaired when
-- Prompter starts: the item note remains authoritative and marker timing stays
-- unchanged.
reset()
do
  local repaired_item = audio(24, 2, 24)
  repaired_item.strings.P_NOTES = "Vivol"
  repaired_item.strings[montage_model.MANAGED_AUDIO_KEY] = "1"
  subtitle_model.set_audio_words(repaired_item.take, {
    { 24.405, 25.192, " виброл." },
  })
  local repaired = montage_model.sync_audio_notes_to_words(subtitle_model)
  assert(repaired == 1)
  local repaired_words = subtitle_model.get_audio_words(repaired_item.take)
  assert(repaired_words[1][1] == 24.405 and repaired_words[1][2] == 25.192)
  assert(repaired_words[1][3]:find("Vivol", 1, true))
  assert(repaired_item.take.markers[1].name:find("Vivol", 1, true))
end

local function mark_phrase(audio_items, subtitle_items, words, signature)
  local phrase_id = "phrase1"
  local serialized = montage_model.serialize_source_words(words)
  for _, item in ipairs(audio_items) do
    item.strings[montage_model.PHRASE_ID_KEY] = phrase_id
    item.strings[montage_model.MANAGED_AUDIO_KEY] = "1"
    item.strings[montage_model.SOURCE_WORDS_KEY] = serialized
  end
  for _, item in ipairs(subtitle_items) do
    item.strings[montage_model.PHRASE_ID_KEY] = phrase_id
    item.strings[montage_model.GENERATED_SUBTITLE_KEY] = "1"
    item.strings[montage_model.WORD_SIGNATURE_KEY] =
      signature or montage_model.word_signature(words)
  end
end

-- Existing grouped projects are migrated without requiring a new
-- transcription. Relative subtitle words become source-media word timing.
reset()
local legacy_audio = audio(20, 5, 100)
local legacy_sub = subtitle(20, 5, "Legacy phrase")
subtitle_model.set_relative_words(legacy_sub, {
  { 1, 2, " Legacy" },
  { 2.2, 3, " phrase" },
})
local changed, stats, err =
  montage_model.reconcile_project(subtitle_model)
assert(changed and not err)
assert(stats.migrated == 1)
assert(legacy_audio.strings[montage_model.PHRASE_ID_KEY] ~= "")
local migrated_words = montage_model.parse_source_words(
  legacy_audio.strings[montage_model.SOURCE_WORDS_KEY])
assert(#migrated_words == 2)
assert(math.abs(migrated_words[1][1] - 101) < 0.000001)

-- Native Split duplicated the subtitle over a silent tail. The silent audio
-- child must leave the group and the duplicate subtitle must disappear.
reset()
local speech = audio(0, 9, 0)
local silence = audio(9, 1, 9)
local left_sub = subtitle(0, 9, "Hello world")
local empty_clone = subtitle(9, 1, "Hello world")
local words = {
  { 1, 2, " Hello" },
  { 7, 8, " world" },
}
mark_phrase({ speech, silence }, { left_sub, empty_clone }, words)
changed, stats, err = montage_model.reconcile_project(subtitle_model)
assert(changed and not err)
assert(#tracks[2].items == 1, "silent subtitle clone was not deleted")
assert(silence.values.I_GROUPID == 0, "silent audio remained in phrase group")
assert(tracks[2].items[1].strings.P_NOTES == "Hello world")

-- Deleting a spoken source interval must remove its word from the projection.
reset()
local first = audio(0, 3, 0)
local last = audio(3, 4, 6)
local sub = subtitle(0, 7, "One two three")
local three_words = {
  { 1, 2, " One" },
  { 4, 5, " two" },
  { 7, 8, " three" },
}
mark_phrase(
  { first, last }, { sub }, three_words,
  montage_model.word_signature(three_words))
changed, stats, err = montage_model.reconcile_project(subtitle_model)
assert(changed and not err)
assert(sub.strings.P_NOTES == "One three", "deleted spoken word remained")

-- Removing silence with Ripple keeps the complete manually corrected text and
-- joins the surviving audio descendants into one subtitle projection.
reset()
local before = audio(0, 3, 0)
local after = audio(3, 4, 6)
local sub_a = subtitle(0, 3, "Corrected phrase")
local sub_b = subtitle(3, 4, "Corrected phrase")
local two_words = {
  { 1, 2, " Raw" },
  { 7, 8, " words" },
}
mark_phrase({ before, after }, { sub_a, sub_b }, two_words)
sub_a.strings[montage_model.MANUAL_TEXT_KEY] = "1"
changed, stats, err = montage_model.reconcile_project(subtitle_model)
assert(changed and not err)
assert(#tracks[2].items == 1)
assert(tracks[2].items[1].strings.P_NOTES == "Corrected phrase",
  "manual text changed when only silence was removed")

print("ReaTitles montage model tests: OK")
