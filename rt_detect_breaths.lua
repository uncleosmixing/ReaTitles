-- @description Detect breaths and create volume automation (YAMNet ONNX)
-- @version 1.0.0
-- @author ReaTitles
-- @changelog + Initial release
-- @about
--   Detect breaths in vocal recordings using YAMNet neural network.
--   Creates volume automation envelopes to reduce breath volume.
--   Requires: Python 3.8+, onnxruntime, numpy, scipy.

local PYTHON_SCRIPT = "rt_breath_detect.py"
local r = reaper

local function msg(_) end

local function get_script_dir()
  local info = debug.getinfo(1, "S")
  if info and info.source then
    local path = info.source:match("^@(.+)")
    if path then return path:match("^(.*[/\\])") or "" end
  end
  return ""
end

local model_ok, breath_model =
  pcall(dofile, get_script_dir() .. "rt_breath_model.lua")
if not model_ok then
  r.ShowMessageBox(
    "rt_breath_model.lua is missing.\n" .. tostring(breath_model),
    "Breath Detection error", 0)
  return
end

local function find_python()
  for _, cmd in ipairs({"python", "python3", "py"}) do
    local h = io.popen(cmd .. ' --version 2>&1')
    if h then
      local out = h:read("*a"); h:close()
      if out:match("Python 3%.") then return cmd end
    end
  end
  return nil
end

local function ensure_dependencies(python)
  local checks = {
    {module = "onnxruntime", name = "onnxruntime"},
    {module = "numpy", name = "numpy"},
    {module = "scipy", name = "scipy"},
  }
  local missing = {}
  for _, check in ipairs(checks) do
    local ok = os.execute(python .. ' -c "import ' .. check.module .. '"')
    if ok ~= true and ok ~= 0 then
      missing[#missing+1] = check.name
    end
  end
  if #missing == 0 then return true end

  r.ShowMessageBox(
    "Missing Python packages: " .. table.concat(missing, ", ") ..
    "\n\nInstall them:\npip install " .. table.concat(missing, " "),
    "Breath Detection", 0)
  return false
end

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
      for k, v in pairs(val) do
        p[#p+1] = json_encode(tostring(k)) .. ":" .. json_encode(v)
      end
      return "{" .. table.concat(p, ",") .. "}"
    end
  end
  return "null"
end

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

local function write_wav(path, samples, sample_rate)
  local num_samples = #samples
  local data_size = num_samples * 2
  local file_size = 36 + data_size

  local f = io.open(path, "wb")
  if not f then return false end

  f:write("RIFF")
  f:write(string.pack("<I", file_size))
  f:write("WAVE")
  f:write("fmt ")
  f:write(string.pack("<I", 16))
  f:write(string.pack("<HHIIHH", 1, 1, sample_rate, sample_rate * 2, 2, 16))
  f:write("data")
  f:write(string.pack("<I", data_size))

  for i = 1, num_samples do
    local s = math.max(-1, math.min(1, samples[i]))
    local val = math.floor(s * 32767 + 0.5)
    if s < 0 then val = math.floor(s * 32768 - 0.5) end
    val = math.max(-32768, math.min(32767, val))
    f:write(string.pack("<h", val))
  end

  f:close()
  return true
end

local function extract_audio_to_wav(item, output_path)
  local take = r.GetActiveTake(item)
  if not take then return false end

  local src = r.GetMediaItemTake_Source(take)
  if not src then return false end

  local sample_rate = r.GetMediaSourceSampleRate(src)
  if sample_rate <= 0 then sample_rate = 44100 end

  local accessor = r.CreateTakeAudioAccessor(take)
  if not accessor then return false end

  local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if rate <= 0 then rate = 1 end
  local offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local start_offset = math.max(0, offs)
  local duration = item_len * rate

  local num_samples = math.floor(duration * sample_rate)
  if num_samples <= 0 then
    r.DestroyAudioAccessor(accessor)
    return false
  end

  local buffer = r.new_array(num_samples)
  local ok = r.GetAudioAccessorSamples(accessor, sample_rate, 1,
    start_offset, num_samples, buffer)
  r.DestroyAudioAccessor(accessor)

  if ok <= 0 then return false end

  local samples = buffer.table()
  return write_wav(output_path, samples, sample_rate)
end

local function find_or_create_volume_envelope(track)
  local envelope = r.GetTrackEnvelopeByName(track, "Volume")
  if envelope then return envelope end

  r.GetSetMediaTrackInfo_String(track, "I_TCPYPC_USED", "1", true)
  local _, chunk = r.GetSetMediaTrackInfo_String(track, "P_EXT:recalc", "", false)

  local idx = r.CountTrackEnvelopes(track)
  if idx == 0 then
    r.Main_OnCommand(40347, 0)
    envelope = r.GetTrackEnvelopeByName(track, "Volume")
    if envelope then return envelope end
  end

  for i = 0, idx - 1 do
    local env = r.GetTrackEnvelope(track, i)
    if env then
      local _, name = r.GetEnvelopeName(env, "")
      if name == "Volume" then return env end
    end
  end

  r.Main_OnCommand(40347, 0)
  return r.GetTrackEnvelopeByName(track, "Volume")
end

local function create_automation_points(envelope, breaths, reduction_db, item_pos)
  if not envelope or not breaths or #breaths == 0 then return 0 end

  local vol_linear = 10 ^ (reduction_db / 20)
  local fade_time = 0.05
  local points_created = 0

  for _, breath in ipairs(breaths) do
    local b_start = item_pos + breath.start
    local b_end = item_pos + breath.end

    r.SetEnvelopePoint(envelope, b_start - fade_time, 1.0, 0, 0, false)
    r.SetEnvelopePoint(envelope, b_start, vol_linear, 0, 0, false)
    r.SetEnvelopePoint(envelope, b_end, vol_linear, 0, 0, false)
    r.SetEnvelopePoint(envelope, b_end + fade_time, 1.0, 0, 0, false)
    points_created = points_created + 4
  end

  if points_created > 0 then
    r.Envelope_SortPoints(envelope)
  end

  return points_created
end

local function main()
  local sel_count = r.CountSelectedMediaItems(0)
  if sel_count == 0 then
    r.ShowMessageBox("Select audio item(s) for breath detection.", "Breath Detection", 0)
    return
  end

  local python = find_python()
  if not python then
    r.ShowMessageBox("Python 3 not found.\nhttps://www.python.org/downloads/",
      "Breath Detection", 0)
    return
  end

  if not ensure_dependencies(python) then return end

  if not breath_model.model_exists() then
    local ok = breath_model.ensure_model()
    if not ok then
      r.ShowMessageBox("Could not download YAMNet model.\nCheck internet connection.",
        "Breath Detection", 0)
      return
    end
  end

  local script_dir = get_script_dir()

  local threshold = 0.3
  local reduction_db = -12
  local min_duration = 100
  local merge_gap = 300

  local tmpdir = script_dir .. "tmp_breath" .. package.config:sub(1,1)
  os.execute('mkdir "' .. tmpdir .. '" 2>nul')

  local items_data = {}
  local source_items = {}
  local source_tracks = {}

  for i = 0, sel_count - 1 do
    local item = r.GetSelectedMediaItem(0, i)
    if item then
      local take = r.GetActiveTake(item)
      if take then
        local wav_path = tmpdir .. string.format("item_%d.wav", i)
        if extract_audio_to_wav(item, wav_path) then
          local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
          local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
          local rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
          if rate <= 0 then rate = 1 end

          items_data[#items_data+1] = {
            wav = wav_path,
            duration = item_len * rate,
            index = #items_data + 1,
          }
          source_items[#source_items+1] = item
          source_tracks[#source_tracks+1] = r.GetMediaItem_Track(item)
        end
      end
    end
  end

  if #items_data == 0 then
    r.ShowMessageBox("Could not extract audio from selected items.", "Breath Detection", 0)
    return
  end

  local items_path = tmpdir .. "items.json"
  local output_path = tmpdir .. "output.json"
  local status_path = tmpdir .. "status.json"
  local progress_path = tmpdir .. "progress.json"
  local log_path = tmpdir .. "breath_detect.log"

  os.remove(output_path)
  os.remove(status_path)
  os.remove(status_path .. ".tmp")
  os.remove(progress_path)
  os.remove(progress_path .. ".tmp")
  os.remove(log_path)

  local f = io.open(items_path, "w")
  if not f then
    r.ShowMessageBox("Cannot create temp file.", "Breath Detection", 0)
    return
  end
  f:write(json_encode(items_data))
  f:close()

  local class_map_path = breath_model.MODEL_DIR .. "yamnet_class_map.csv"

  local cmd = string.format(
    '%s "%s%s" --items "%s" --output "%s" --model "%s" --class-map "%s" --threshold %g --min-duration %g --merge-gap %g',
    python, script_dir, PYTHON_SCRIPT,
    items_path:gsub("\\","/"), output_path:gsub("\\","/"),
    breath_model.MODEL_PATH:gsub("\\","/"),
    class_map_path:gsub("\\","/"),
    threshold, min_duration, merge_gap)
  cmd = cmd .. string.format(' --status "%s" --progress "%s"',
    status_path:gsub("\\","/"), progress_path:gsub("\\","/"))

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
    r.ShowMessageBox("Cannot start Python breath detection process.", "Breath Detection", 0)
    return
  end

  local started_at = r.time_precise()
  local progress_ctx = r.ImGui_CreateContext and
    r.ImGui_CreateContext("Breath Detection") or nil
  local progress_window_open = true
  local cached_progress = {
    percent = 0, phase = "starting", detail = "Starting detection",
    item = 0, total_items = #items_data, elapsed = 0,
  }
  local displayed_percent = 0

  local phase_labels = {
    starting = "Запуск",
    model = "Загрузка модели YAMNet",
    model_ready = "Модель загружена",
    detecting = "Анализ аудио",
    inferring = "Нейросеть",
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
    for _, item in ipairs(items_data) do
      if item.wav then os.remove(item.wav) end
    end
    os.execute('rmdir "' .. tmpdir .. '" 2>nul')
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

    if p.phase == "done" then
      displayed_percent = 1
    elseif target_percent < displayed_percent then
      displayed_percent = target_percent
    elseif target_percent > displayed_percent then
      displayed_percent = math.min(target_percent, displayed_percent + 0.001)
    end
    displayed_percent = math.floor(displayed_percent * 1000 + 0.5) / 1000

    r.ImGui_SetNextWindowSize(progress_ctx, 420, 0, r.ImGui_Cond_FirstUseEver())
    local visible, open = r.ImGui_Begin(
      progress_ctx, "Breath Detection", true,
      r.ImGui_WindowFlags_AlwaysAutoResize())
    progress_window_open = open ~= false
    if visible then
      local phase = phase_labels[p.phase] or tostring(p.detail or p.phase or "")
      r.ImGui_Text(progress_ctx, phase)
      r.ImGui_ProgressBar(
        progress_ctx, displayed_percent, -1, 24,
        string.format("%.1f%%", displayed_percent * 100))

      local item_no = tonumber(p.item) or 0
      local total = tonumber(p.total_items) or #items_data
      if total > 0 then
        r.ImGui_Text(progress_ctx, string.format("Фрагмент: %d из %d", item_no, total))
      end
      if p.detail and p.detail ~= "" then
        r.ImGui_TextWrapped(progress_ctx, tostring(p.detail))
      end
      local elapsed = tonumber(p.elapsed) or (r.time_precise() - started_at)
      r.ImGui_TextDisabled(
        progress_ctx, string.format("Прошло: %02d:%02d",
          math.floor(elapsed / 60), math.floor(elapsed % 60)))
      r.ImGui_End(progress_ctx)
    end
  end

  local function finish_detection()
    local sf = io.open(status_path, "r")
    if not sf then return false end
    local status_content = sf:read("*a")
    sf:close()

    local status_ok, status = pcall(json_decode, status_content)
    if not status_ok or type(status) ~= "table" then
      cleanup_temp()
      r.ShowMessageBox("Invalid detection status file.\nSee: " .. log_path,
        "Breath Detection", 0)
      return true
    end
    if not status.ok then
      local err = status.error or "Unknown error"
      local log_content = ""
      local log_file = io.open(log_path, "r")
      if log_file then
        log_content = log_file:read("*a") or ""
        log_file:close()
      end
      msg("[ERROR] Detection failed: " .. tostring(err))
      if log_content ~= "" then
        msg("[Log]\n" .. log_content)
      end
      cleanup_temp()
      r.ShowMessageBox("Detection failed:\n" .. err .. "\n\nLog:\n" .. log_path,
        "Breath Detection", 0)
      return true
    end

    local f2 = io.open(output_path, "r")
    if not f2 then
      cleanup_temp()
      r.ShowMessageBox("Result file was not created.\nSee: " .. log_path,
        "Breath Detection", 0)
      return true
    end
    local content = f2:read("*a")
    f2:close()
    local ok, results = pcall(json_decode, content)
    if not ok or type(results) ~= "table" then
      cleanup_temp()
      r.ShowMessageBox("Cannot parse detection result.\nSee: " .. log_path,
        "Breath Detection", 0)
      return true
    end

    r.Undo_BeginBlock()
    r.PreventUIRefresh(1)

    local total_breaths = 0
    local total_points = 0

    for i, src_item in ipairs(source_items) do
      local track = source_tracks[i]
      local result = results[i]
      if r.ValidatePtr(src_item, "MediaItem*") and track and
         r.ValidatePtr(track, "MediaTrack*") and result then
        local breaths = result.breaths or {}
        if #breaths > 0 then
          local envelope = find_or_create_volume_envelope(track)
          if envelope then
            local item_pos = r.GetMediaItemInfo_Value(src_item, "D_POSITION")
            local pts = create_automation_points(envelope, breaths, reduction_db, item_pos)
            total_breaths = total_breaths + #breaths
            total_points = total_points + pts
          end
        end
      end
    end

    r.PreventUIRefresh(-1)
    r.UpdateArrange()
    r.Undo_EndBlock("Breath Detection: Create automation", -1)

    cleanup_temp()

    r.ShowMessageBox(
      string.format(
        "Готово!\n\nНайдено дыханий: %d\nСоздано точек автоматизации: %d\n\n" ..
        "Громкость дыханий снижена на %d dB.\n" ..
        "Вы можете отрегулировать уровень вручную, редактируя огибающую.",
        total_breaths, total_points, reduction_db),
      "Breath Detection", 0)

    return true
  end

  local function poll()
    draw_progress()
    if finish_detection() then return end
    if r.time_precise() - started_at > 7200 then
      cleanup_temp()
      r.ShowMessageBox("Detection timed out after 2 hours.\nSee: " .. log_path,
        "Breath Detection", 0)
      return
    end
    r.defer(poll)
  end
  r.defer(poll)
end

main()
