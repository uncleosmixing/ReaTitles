-- @description YAMNet breath detection model path helper
-- @version 1.0.0
-- @about
--   Provides model path and auto-download for YAMNet ONNX breath detection.

local M = {}

local MODEL_URL = "https://github.com/onnx/models/raw/main/verified_examples/audio/yamnet/yamnet.onnx"
local MODEL_SHA256 = nil
local MODEL_FILENAME = "yamnet.onnx"

local function get_script_dir()
  local info = debug.getinfo(1, "S")
  if info and info.source then
    local path = info.source:match("^@(.+)")
    if path then return path:match("^(.*[/\\])") or "" end
  end
  return ""
end

M.SCRIPT_DIR = get_script_dir()
M.MODEL_DIR = M.SCRIPT_DIR .. "models" .. package.config:sub(1,1)
M.MODEL_PATH = M.MODEL_DIR .. MODEL_FILENAME

function M.model_exists()
  local f = io.open(M.MODEL_PATH, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

function M.ensure_model(progress_callback)
  if M.model_exists() then
    return true
  end

  local reaper = reaper
  if not reaper then return false end

  os.execute('mkdir "' .. M.MODEL_DIR .. '" 2>nul')

  if progress_callback then
    progress_callback("model_download", "Downloading YAMNet ONNX model...")
  end

  local tmp_path = M.MODEL_PATH .. ".tmp"
  os.remove(tmp_path)

  local cmd
  local is_windows = reaper.GetOS():match("Win") ~= nil
  if is_windows then
    cmd = string.format(
      'cmd.exe /D /S /C curl -L -o "%s" "%s"',
      tmp_path:gsub("/", "\\"), MODEL_URL)
  else
    cmd = string.format('curl -L -o "%s" "%s"', tmp_path, MODEL_URL)
  end

  local ok = os.execute(cmd)
  if ok ~= true and ok ~= 0 then
    os.remove(tmp_path)
    return false
  end

  local f = io.open(tmp_path, "rb")
  if not f then return false end
  local size = f:seek("end")
  f:close()

  if size < 1000000 then
    os.remove(tmp_path)
    return false
  end

  os.rename(tmp_path, M.MODEL_PATH)
  return M.model_exists()
end

return M
