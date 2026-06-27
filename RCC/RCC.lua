-- @description Room Control Center
-- @author Uncle Os
-- @version 1.0.1
-- @changelog
--   + Initial ReaPack release
-- @link https://github.com/uncleosmixing/Uncle-Os
-- @about
--   # Room Control Center
--
--   Dockable monitoring, metering, reference playback and headphone correction
--   control center for REAPER.
--
--   Requires ReaImGui.

local script_dir = debug.getinfo(1, "S").source:match("@?(.*[\\/])") or ""
package.path = script_dir .. "?.lua;"
  .. script_dir .. "Shared/?.lua;"
  .. script_dir .. "../Shared/?.lua;"
  .. script_dir .. "UI/?.lua;"
  .. script_dir .. "Core/?.lua;"
  .. package.path

local RCCModule = require("RCCModule")
RCCModule.ReloadAll()

local MonitorPanel = require("MonitorPanel")
local MonitorManager = require("MonitorManager")
local UIUtils = require("UIUtils")

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox("Room Control Center requires ReaImGui.", "RCC", 0)
  return
end

local ctx = reaper.ImGui_CreateContext("RCC")
local font_size = 15
local font = reaper.ImGui_CreateFont("sans-serif", font_size)
reaper.ImGui_Attach(ctx, font)
local small_font_size = 10
local small_font = reaper.ImGui_CreateFont("sans-serif", small_font_size)
reaper.ImGui_Attach(ctx, small_font)

local state = MonitorManager.CreateState()
local next_window_height = nil

local function UpdateNextWindowHeight()
  if not reaper.ImGui_GetWindowPos or not reaper.my_getViewport then
    return
  end

  local _, window_y = reaper.ImGui_GetWindowPos(ctx)
  local _, _, _, work_bottom = reaper.my_getViewport(0, 0, 0, 0, 0, 0, 0, 0, true)

  if window_y and work_bottom and work_bottom > window_y then
    next_window_height = math.max(360, work_bottom - window_y - 4)
  end
end

local function SetDockingPreference()
  if not reaper.ImGui_SetNextWindowDockID then
    return
  end

  local dock_id = reaper.GetExtState("RCC", "dock_id")
  dock_id = tonumber(dock_id)
  if dock_id and dock_id ~= 0 then
    reaper.ImGui_SetNextWindowDockID(ctx, dock_id, reaper.ImGui_Cond_FirstUseEver())
  end
end

local function RememberDockID()
  if not reaper.ImGui_GetWindowDockID then
    return
  end

  local dock_id = reaper.ImGui_GetWindowDockID(ctx)
  if dock_id and dock_id ~= 0 then
    reaper.SetExtState("RCC", "dock_id", tostring(dock_id), true)
  end
end

local function HandleGlobalReaperShortcuts()
  local item_active = reaper.ImGui_IsAnyItemActive and reaper.ImGui_IsAnyItemActive(ctx)
  if item_active then return end

  local mods = reaper.ImGui_GetKeyMods and reaper.ImGui_GetKeyMods(ctx) or 0
  local ctrl_flag = reaper.ImGui_Mod_Ctrl and reaper.ImGui_Mod_Ctrl() or 0
  local shift_flag = reaper.ImGui_Mod_Shift and reaper.ImGui_Mod_Shift() or 0
  local ctrl = ctrl_flag ~= 0 and ((mods & ctrl_flag) ~= 0)
  local shift = shift_flag ~= 0 and ((mods & shift_flag) ~= 0)

  local function key_pressed(key_fn)
    return key_fn and reaper.ImGui_IsKeyPressed and reaper.ImGui_IsKeyPressed(ctx, key_fn())
  end

  if key_pressed(reaper.ImGui_Key_Space) then
    reaper.Main_OnCommandEx(40044, 0, 0)
  elseif ctrl and shift and key_pressed(reaper.ImGui_Key_Z) then
    reaper.Main_OnCommandEx(40030, 0, 0)
  elseif ctrl and key_pressed(reaper.ImGui_Key_Y) then
    reaper.Main_OnCommandEx(40030, 0, 0)
  elseif ctrl and key_pressed(reaper.ImGui_Key_Z) then
    reaper.Main_OnCommandEx(40029, 0, 0)
  elseif ctrl and key_pressed(reaper.ImGui_Key_S) then
    reaper.Main_OnCommandEx(40026, 0, 0)
  elseif not ctrl and not shift and key_pressed(reaper.ImGui_Key_R) then
    reaper.Main_OnCommandEx(1013, 0, 0)
  end
end

local function Loop()
  reaper.ImGui_PushFont(ctx, font, font_size)
  if next_window_height then
    local cond_always = reaper.ImGui_Cond_Always and reaper.ImGui_Cond_Always() or 0
    reaper.ImGui_SetNextWindowSize(ctx, 300, next_window_height, cond_always)
  end

  SetDockingPreference()

  local flags = 0
  if reaper.ImGui_WindowFlags_NoScrollbar then
    flags = flags | reaper.ImGui_WindowFlags_NoScrollbar()
  end
  if reaper.ImGui_WindowFlags_NoScrollWithMouse then
    flags = flags | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  end

  UIUtils.RefreshTheme(false)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), UIUtils.ThemeColor("window_bg", 0x303030FF))
  local visible, open = reaper.ImGui_Begin(ctx, "RCC", true, flags)
  if visible then
    HandleGlobalReaperShortcuts()
    RememberDockID()
    UpdateNextWindowHeight()
    MonitorPanel.Draw(ctx, state, MonitorManager, small_font, small_font_size)
    reaper.ImGui_End(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_PopFont(ctx)

  if open then
    reaper.defer(Loop)
  elseif reaper.ImGui_DestroyContext then
    reaper.ImGui_DestroyContext(ctx)
  end
end

reaper.defer(Loop)
