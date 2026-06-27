-- @description Transcribe audio items to subtitle text items (Whisper)
-- @version 1.2.5
-- @author ReaTitles
-- @changelog + Initial release
-- @about
--   # Transcribe audio to subtitles
--   Select audio items, run script, get text items on a subtitle track.
--   Uses Python + faster-whisper for offline speech recognition.
--   Requires: Python 3.8+, faster-whisper, FFmpeg.

local PYTHON_SCRIPT = "rt_whisper_transcribe.py"
local SUBTITLE_TRACK_NAME = "Subtitles"
local SCRIPT_VERSION = "1.2.5"
local r = reaper

local function msg(s) r.ShowConsoleMsg(tostring(s) .. "\n") end

local function get_script_dir()
  local info = debug.getinfo(1, "S")
  if info and info.source then
    local path = info.source:match("^@(.+)")
    if path then return path:match("^(.*[/\\])") or "" end
  end
  return ""
end

local function find_python()
  for _, cmd in ipairs({"python", "python3", "py"}) do
    local h = io.popen(cmd .. ' --version 2>&1')
    if h then
      local r = h:read("*a"); h:close()
      if r:match("Python 3%.") then return cmd end
    end
  end
  return nil
end

local function ensure_dependencies(python, script_dir)
  local whisper_check = os.execute(python .. ' -c "import faster_whisper"')
  local ffmpeg_check = os.execute(
    python .. ' -c "import glob,os,shutil,sys; ' ..
    "root=os.path.join(os.environ.get('LOCALAPPDATA',''),'Microsoft','WinGet','Packages'); " ..
    "found=shutil.which('ffmpeg') or glob.glob(os.path.join(root,'Gyan.FFmpeg*','**','ffmpeg.exe'),recursive=True); " ..
    'sys.exit(0 if found else 1)"')
  local whisper_ok = whisper_check == true or whisper_check == 0
  local ffmpeg_ok = ffmpeg_check == true or ffmpeg_check == 0
  if whisper_ok and ffmpeg_ok then return true end

  local installer = script_dir .. "rt_install_dependencies.py"
  if not r.file_exists(installer) then
    msg("[ReaTitles ERROR] Missing installer helper: " .. installer)
    r.ShowMessageBox("Dependency installer is missing.\nUpdate ReaTitles through ReaPack.",
      "ReaTitles dependency error", 0)
    return false
  end

  local status_path = script_dir .. "rt_setup_status.txt"
  local log_path = script_dir .. "rt_setup.log"
  os.remove(status_path)
  os.remove(log_path)
  local command = string.format(
    'cmd.exe /D /S /C start "" /B %s "%s" --status "%s" --log "%s"',
    python, installer, status_path, log_path)
  local launched = os.execute(command)
  if launched ~= true and launched ~= 0 then
    msg("[ReaTitles ERROR] Could not start dependency installer.")
    return false
  end

  msg("[ReaTitles SETUP] Installing missing transcription dependencies in the background.")
  if not whisper_ok then msg("[ReaTitles SETUP] Missing: faster-whisper") end
  if not ffmpeg_ok then msg("[ReaTitles SETUP] Missing: FFmpeg") end
  msg("[ReaTitles SETUP] REAPER remains available. Run transcription again after success.")
  local started = r.time_precise()
  local shown_bytes = 0
  local setup_ctx = r.ImGui_CreateContext and
                    r.ImGui_CreateContext("ReaTitles Setup") or nil

  local function poll_setup()
    local log = io.open(log_path, "r")
    if log then
      local content = log:read("*a") or ""
      log:close()
      if #content > shown_bytes then
        msg(content:sub(shown_bytes + 1))
        shown_bytes = #content
      end
    end

    local status = io.open(status_path, "r")
    if status then
      local code = tonumber(status:read("*a"))
      status:close()
      os.remove(status_path)
      if code == 0 then
        msg("[ReaTitles SETUP] Transcription dependencies installed successfully.")
        r.ShowMessageBox(
          "Transcription dependencies installed successfully.\n\nRun transcription again.",
          "ReaTitles setup", 0)
      else
        msg("[ReaTitles ERROR] Dependency installation failed. See rt_setup.log.")
        r.ShowMessageBox(
          "Dependency installation failed.\n\nSee the REAPER console and:\n" ..
          log_path, "ReaTitles setup", 0)
      end
      return
    end

    if setup_ctx then
      r.ImGui_SetNextWindowSize(setup_ctx, 430, 0, r.ImGui_Cond_FirstUseEver())
      local visible = r.ImGui_Begin(
        setup_ctx, "ReaTitles — Installing dependencies", true,
        r.ImGui_WindowFlags_AlwaysAutoResize())
      if visible then
        local elapsed = math.floor(r.time_precise() - started)
        r.ImGui_Text(setup_ctx, "Installing transcription dependencies...")
        r.ImGui_Text(setup_ctx, string.format("Elapsed: %02d:%02d",
          math.floor(elapsed / 60), elapsed % 60))
        r.ImGui_TextWrapped(setup_ctx,
          "REAPER is not frozen. Detailed output is shown in the ReaScript console.")
        r.ImGui_End(setup_ctx)
      end
    end
    r.defer(poll_setup)
  end
  r.defer(poll_setup)
  return false
end

-- JSON encoder
local function json_encode(val)
  local t = type(val)
  if t == "nil" then return "null"
  elseif t == "boolean" then return val and "true" or "false"
  elseif t == "number" then return tostring(val)
  elseif t == "string" then
    return '"' .. val:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t') .. '"'
  elseif t == "table" then
    if val[1] ~= nil or next(val) == nil then
      local p = {}
      for i, v in ipairs(val) do p[i] = json_encode(v) end
      return "[" .. table.concat(p, ",") .. "]"
    else
      local p = {}
      for k, v in pairs(val) do p[#p+1] = json_encode(tostring(k)) .. ":" .. json_encode(v) end
      return "{" .. table.concat(p, ",") .. "}"
    end
  end
  return "null"
end

-- JSON decoder (preserves spaces in strings)
local function json_decode(str)
  local pos = 1
  local function skip_ws()
    while pos <= #str do
      local c = str:sub(pos, pos)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then pos = pos + 1 else break end
    end
  end
  local function parse_string()
    pos = pos + 1; local r = {}
    while pos <= #str do
      local c = str:sub(pos, pos)
      if c == '"' then pos = pos + 1; return table.concat(r)
      elseif c == '\\' then pos = pos + 1; local e = str:sub(pos, pos)
        if e == 'n' then r[#r+1]='\n' elseif e == 'r' then r[#r+1]='\r'
        elseif e == 't' then r[#r+1]='\t' elseif e == '"' then r[#r+1]='"'
        elseif e == '\\' then r[#r+1]='\\' else r[#r+1]=e end
        pos = pos + 1
      else r[#r+1] = c; pos = pos + 1 end
    end
    return table.concat(r)
  end
  local parse_value
  local function parse_number()
    local s = pos
    if str:sub(pos,pos) == '-' then pos = pos+1 end
    while pos <= #str and str:sub(pos,pos):match("[%d%.eE%+%-]") do pos = pos+1 end
    return tonumber(str:sub(s, pos-1))
  end
  local function parse_array()
    pos = pos+1; local a = {}; skip_ws()
    if str:sub(pos,pos) == ']' then pos=pos+1; return a end
    while true do a[#a+1]=parse_value(); skip_ws()
      if str:sub(pos,pos)==',' then pos=pos+1 else break end end
    skip_ws(); if str:sub(pos,pos)==']' then pos=pos+1 end; return a
  end
  local function parse_object()
    pos = pos+1; local o = {}; skip_ws()
    if str:sub(pos,pos) == '}' then pos=pos+1; return o end
    while true do skip_ws(); local k=parse_string(); skip_ws()
      if str:sub(pos,pos)==':' then pos=pos+1 end
      o[k]=parse_value(); skip_ws()
      if str:sub(pos,pos)==',' then pos=pos+1 else break end end
    skip_ws(); if str:sub(pos,pos)=='}' then pos=pos+1 end; return o
  end
  parse_value = function()
    skip_ws(); local c = str:sub(pos,pos)
    if c=='"' then return parse_string()
    elseif c=='{' then return parse_object()
    elseif c=='[' then return parse_array()
    elseif c=='t' then pos=pos+4; return true
    elseif c=='f' then pos=pos+5; return false
    elseif c=='n' then pos=pos+4; return nil
    else return parse_number() end
  end
  return parse_value()
end

-- Create text item (chirick86 pattern)
local function create_text_item(track, start_time, end_time, text)
  if not track then return nil end
  local item = r.AddMediaItemToTrack(track)
  if not item then return nil end
  if end_time <= start_time then end_time = start_time + 0.5 end
  r.SetMediaItemPosition(item, start_time, false)
  r.SetMediaItemLength(item, end_time - start_time, false)
  r.GetSetMediaItemInfo_String(item, "P_NOTES", text, true)
  r.SetMediaItemInfo_Value(item, "C_LANEDISP", 3)
  return item
end

-- Store absolute project-time word boundaries in a compact item extension.
-- REAPER copies P_EXT fields when an item is split, allowing Prompter to
-- reconstruct the correct text independently for every resulting piece.
local function store_word_timing(item, words, item_pos, rate)
  if not item or type(words) ~= "table" or #words == 0 then return end
  local rows = {}
  for _, word in ipairs(words) do
    if type(word) == "table" and tonumber(word[1]) and tonumber(word[2]) and
       type(word[3]) == "string" then
      local start_pos = item_pos + tonumber(word[1]) / rate
      local end_pos = item_pos + tonumber(word[2]) / rate
      local text = word[3]:gsub("[\r\n\t]", " ")
      rows[#rows+1] = string.format("%.9f\t%.9f\t%s", start_pos, end_pos, text)
    end
  end
  if #rows > 0 then
    r.GetSetMediaItemInfo_String(
      item, "P_EXT:REATITLES_WORD_TIMING", table.concat(rows, "\n"), true)
  end
end

-- Find or create subtitle track
local function find_or_create_track()
  for i = 0, r.CountTracks(0)-1 do
    local tr = r.GetTrack(0, i)
    local _, n = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if n == SUBTITLE_TRACK_NAME then return tr end
  end
  r.Main_OnCommand(40001, 0)
  local tr = r.GetSelectedTrack(0, 0)
  if tr then r.GetSetMediaTrackInfo_String(tr, "P_NAME", SUBTITLE_TRACK_NAME, true) end
  return tr
end

-----------------------------------------------------------
-- Main
-----------------------------------------------------------
local function main()
  local sel_count = r.CountSelectedMediaItems(0)
  if sel_count == 0 then
    r.ShowMessageBox("Select audio item(s) for transcription.", "ReaTitles", 0)
    return
  end

  local python = find_python()
  if not python then
    msg("[ReaTitles ERROR] Python 3 was not found. Offline transcription cannot start.")
    r.ShowMessageBox("Python 3 not found.\nhttps://www.python.org/downloads/", "ReaTitles", 0)
    return
  end

  local script_dir = get_script_dir()

  if not ensure_dependencies(python, script_dir) then return end

  -- Collect items
  local items_json = {}
  local source_items = {}
  for i = 0, sel_count-1 do
    local item = r.GetSelectedMediaItem(0, i)
    if item then
      local take = r.GetActiveTake(item)
      if take then
        local src = r.GetMediaItemTake_Source(take)
        if src then
          local src_name = r.GetMediaSourceFileName(src, "")
          if src_name and src_name ~= "" then
            local len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
            local rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
            local offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
            -- D_STARTOFFS is already expressed in source-media seconds.
            local src_off = math.max(0, offs)
            items_json[#items_json+1] = {
              src = src_name, start = src_off,
              duration = len * rate, index = #items_json + 1
            }
            source_items[#source_items+1] = item
          end
        end
      end
    end
  end

  if #items_json == 0 then
    r.ShowMessageBox("No audio items found.", "ReaTitles", 0)
    return
  end

  -- Write items JSON
  local items_path = script_dir .. "rt_items.json"
  local f = io.open(items_path, "w")
  if not f then r.ShowMessageBox("Cannot create temp file", "ReaTitles", 0); return end
  f:write(json_encode(items_json)); f:close()

  -- Run Python
  local output_path = script_dir .. "rt_output.json"
  local status_path = script_dir .. "rt_status.json"
  local progress_path = script_dir .. "rt_progress.json"
  local log_path = script_dir .. "rt_transcribe.log"
  os.remove(output_path)
  os.remove(status_path)
  os.remove(status_path .. ".tmp")
  os.remove(progress_path)
  os.remove(progress_path .. ".tmp")
  os.remove(log_path)
  local cmd = string.format('%s "%s%s" --items "%s" --output "%s" --model small',
    python, script_dir, PYTHON_SCRIPT,
    items_path:gsub("\\","/"), output_path:gsub("\\","/"))
  cmd = cmd .. string.format(' --status "%s"', status_path:gsub("\\","/"))
  cmd = cmd .. string.format(' --progress "%s"', progress_path:gsub("\\","/"))
  msg("[ReaTitles " .. SCRIPT_VERSION .. "] " .. cmd)

  local is_windows = r.GetOS():match("Win") ~= nil
  local launch_cmd
  if is_windows then
    launch_cmd = string.format('cmd.exe /D /S /C start "" /B %s > "%s" 2>&1',
      cmd, log_path)
  else
    launch_cmd = string.format('%s > "%s" 2>&1 &', cmd, log_path)
  end
  local launched = os.execute(launch_cmd)
  if launched ~= true and launched ~= 0 then
    os.remove(items_path)
    r.ShowMessageBox("Cannot start Python transcription process.", "ReaTitles", 0)
    return
  end

  local started_at = r.time_precise()
  local progress_ctx = r.ImGui_CreateContext and
                       r.ImGui_CreateContext("ReaTitles Transcription") or nil
  local progress_window_open = true
  local cached_progress = {
    percent = 0, phase = "starting", detail = "Starting transcription",
    item = 0, total_items = #items_json, current_file = "", text = "", elapsed = 0
  }
  local displayed_percent = 0

  local phase_labels = {
    starting = "Запуск",
    model = "Загрузка модели Whisper",
    model_ready = "Модель загружена",
    extracting = "Подготовка аудио (FFmpeg)",
    transcribing = "Распознавание речи",
    item_done = "Фрагмент завершён",
    done = "Готово",
  }

  local function cleanup_temp()
    os.remove(items_path)
    os.remove(output_path)
    os.remove(status_path)
    os.remove(status_path .. ".tmp")
    os.remove(progress_path)
    os.remove(progress_path .. ".tmp")
  end

  local function read_progress()
    local pf = io.open(progress_path, "r")
    if not pf then return cached_progress end
    local content = pf:read("*a")
    pf:close()
    local ok, value = pcall(json_decode, content)
    if ok and type(value) == "table" then
      cached_progress = value
    end
    return cached_progress
  end

  local function draw_progress()
    if not progress_ctx or not progress_window_open then return end
    local p = read_progress()
    local target_percent = math.max(0, math.min(1, tonumber(p.percent) or 0))

    -- Whisper reports progress when it emits a completed segment. Animate only
    -- up to that confirmed value, in 0.1% units, so large segment jumps remain
    -- readable without ever pretending that unprocessed audio is complete.
    if p.phase == "done" then
      displayed_percent = 1
    elseif target_percent < displayed_percent then
      displayed_percent = target_percent
    elseif target_percent > displayed_percent then
      displayed_percent = math.min(target_percent, displayed_percent + 0.001)
    end
    displayed_percent = math.floor(displayed_percent * 1000 + 0.5) / 1000

    r.ImGui_SetNextWindowSize(progress_ctx, 480, 0, r.ImGui_Cond_FirstUseEver())
    local visible, open = r.ImGui_Begin(
      progress_ctx, "ReaTitles — Расшифровка", true,
      r.ImGui_WindowFlags_AlwaysAutoResize())
    progress_window_open = open ~= false
    if visible then
      local phase = phase_labels[p.phase] or tostring(p.detail or p.phase or "")
      r.ImGui_Text(progress_ctx, phase)
      r.ImGui_ProgressBar(
        progress_ctx, displayed_percent, -1, 24,
        string.format("%.1f%%", displayed_percent * 100))

      local item_no = tonumber(p.item) or 0
      local total = tonumber(p.total_items) or #items_json
      if total > 0 then
        r.ImGui_Text(progress_ctx, string.format("Фрагмент: %d из %d", item_no, total))
      end
      if p.current_file and p.current_file ~= "" then
        r.ImGui_TextWrapped(progress_ctx, "Файл: " .. tostring(p.current_file))
      end
      if p.text and p.text ~= "" then
        r.ImGui_Separator(progress_ctx)
        r.ImGui_TextWrapped(progress_ctx, tostring(p.text))
      elseif p.detail and p.detail ~= "" then
        r.ImGui_TextWrapped(progress_ctx, tostring(p.detail))
      end
      local elapsed = tonumber(p.elapsed) or (r.time_precise() - started_at)
      r.ImGui_TextDisabled(
        progress_ctx, string.format("Прошло: %02d:%02d",
          math.floor(elapsed / 60), math.floor(elapsed % 60)))
      r.ImGui_End(progress_ctx)
    end
  end

  local function finish_transcription()
    local sf = io.open(status_path, "r")
    if not sf then return false end
    local status_content = sf:read("*a")
    sf:close()

    local status_ok, status = pcall(json_decode, status_content)
    if not status_ok or type(status) ~= "table" then
      cleanup_temp()
      r.ShowMessageBox("Invalid transcription status file.\nSee:\n" .. log_path, "ReaTitles", 0)
      return true
    end
    if not status.ok then
      local err = status.error or "Unknown Python/FFmpeg error"
      local log_content = ""
      local log_file = io.open(log_path, "r")
      if log_file then
        log_content = log_file:read("*a") or ""
        log_file:close()
      end
      msg("[ReaTitles ERROR] Transcription failed: " .. tostring(err))
      if log_content ~= "" then
        msg("[ReaTitles transcription log]\n" .. log_content)
      end
      cleanup_temp()
      r.ShowMessageBox("Transcription failed:\n" .. err .. "\n\nLog:\n" .. log_path, "ReaTitles", 0)
      return true
    end

    local f2 = io.open(output_path, "r")
    if not f2 then
      cleanup_temp()
      r.ShowMessageBox("Result file was not created.\nSee:\n" .. log_path, "ReaTitles", 0)
      return true
    end
    local content = f2:read("*a")
    f2:close()
    local ok, results = pcall(json_decode, content)
    if not ok or type(results) ~= "table" then
      cleanup_temp()
      r.ShowMessageBox("Cannot parse transcription result.\nSee:\n" .. log_path, "ReaTitles", 0)
      return true
    end

    r.Undo_BeginBlock()
    r.PreventUIRefresh(1)
    local mutation_ok, mutation_err = pcall(function()
      local sub_track = find_or_create_track()
      local created = 0
      local max_group = 0
      for ti = 0, r.CountTracks(0)-1 do
        local tr = r.GetTrack(0, ti)
        for j = 0, r.CountTrackMediaItems(tr)-1 do
          local it = r.GetTrackMediaItem(tr, j)
          max_group = math.max(max_group, r.GetMediaItemInfo_Value(it, "I_GROUPID"))
        end
      end
      local next_group = max_group + 1

      for i, src_item in ipairs(source_items) do
        local segments = results[i]
        if r.ValidatePtr(src_item, "MediaItem*") and segments and #segments > 0 then
          local item_pos = r.GetMediaItemInfo_Value(src_item, "D_POSITION")
          local item_len = r.GetMediaItemInfo_Value(src_item, "D_LENGTH")
          local take = r.GetActiveTake(src_item)
          local rate = take and r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1
          if rate <= 0 then rate = 1 end
          local item_end = item_pos + item_len
          table.sort(segments, function(a, b) return a[1] < b[1] end)

          local remainder = src_item
          for seg_index, seg in ipairs(segments) do
            if type(seg) == "table" and tonumber(seg[1]) and tonumber(seg[2]) and
               type(seg[3]) == "string" and remainder and
               r.ValidatePtr(remainder, "MediaItem*") then
              local seg_start = math.max(item_pos, item_pos + tonumber(seg[1]) / rate)
              local seg_end
              local next_seg = segments[seg_index + 1]
              if type(next_seg) == "table" and tonumber(next_seg[1]) then
                -- Keep phrase blocks contiguous: the current phrase (and its
                -- audio piece) ends exactly where the next phrase begins.
                -- Thus pauses belong to the phrase before them and no orphaned
                -- gap items remain between recognized phrases.
                seg_end = item_pos + tonumber(next_seg[1]) / rate
              else
                seg_end = item_pos + tonumber(seg[2]) / rate
              end
              seg_end = math.min(item_end, math.max(seg_start, seg_end))
              if seg_end - seg_start > 0.01 then
                local rem_pos = r.GetMediaItemInfo_Value(remainder, "D_POSITION")
                local rem_end = rem_pos + r.GetMediaItemInfo_Value(remainder, "D_LENGTH")
                local speech_piece = remainder
                if seg_start > rem_pos + 0.000001 then
                  speech_piece = r.SplitMediaItem(remainder, seg_start)
                end
                if speech_piece and r.ValidatePtr(speech_piece, "MediaItem*") then
                  local speech_end = r.GetMediaItemInfo_Value(speech_piece, "D_POSITION") +
                                     r.GetMediaItemInfo_Value(speech_piece, "D_LENGTH")
                  if seg_end < speech_end - 0.000001 then
                    remainder = r.SplitMediaItem(speech_piece, seg_end)
                  else
                    remainder = nil
                  end
                  local sub_item = create_text_item(sub_track, seg_start, seg_end, seg[3])
                  if sub_item then
                    store_word_timing(sub_item, seg[4], item_pos, rate)
                    r.SetMediaItemInfo_Value(speech_piece, "I_GROUPID", next_group)
                    r.SetMediaItemInfo_Value(sub_item, "I_GROUPID", next_group)
                    next_group = next_group + 1
                    created = created + 1
                  end
                end
              end
            end
          end
        end
      end
      r.ShowMessageBox(string.format("Done! Created %d subtitle items.", created), "ReaTitles", 0)
    end)
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
    r.Undo_EndBlock("ReaTitles: Transcribe", -1)
    cleanup_temp()
    if not mutation_ok then
      r.ShowMessageBox("Could not apply transcription:\n" .. tostring(mutation_err), "ReaTitles", 0)
    end
    return true
  end

  local function poll()
    draw_progress()
    if finish_transcription() then return end
    if r.time_precise() - started_at > 7200 then
      cleanup_temp()
      r.ShowMessageBox("Transcription timed out after two hours.\nSee:\n" .. log_path, "ReaTitles", 0)
      return
    end
    r.defer(poll)
  end
  r.defer(poll)
end

main()
