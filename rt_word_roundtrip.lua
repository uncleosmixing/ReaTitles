local r = reaper
local SCRIPT_DIR = (debug.getinfo(1, "S").source:match("^@(.+[\\/])") or "")
local BRIDGE = SCRIPT_DIR .. "rt_word_bridge.ps1"
local ID_KEY = "P_EXT:REATITLES_DOC_ID"

local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64encode(data)
  return ((data:gsub(".", function(x)
    local bits, byte = "", x:byte()
    for i = 8, 1, -1 do bits = bits .. (byte % 2^i - byte % 2^(i-1) > 0 and "1" or "0") end
    return bits
  end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
    if #x < 6 then return "" end
    local c = 0
    for i = 1, 6 do c = c + (x:sub(i,i) == "1" and 2^(6-i) or 0) end
    return alphabet:sub(c+1,c+1)
  end) .. ({"","==","="})[#data % 3 + 1])
end

local function b64decode(data)
  data = data:gsub("[^" .. alphabet .. "=]", "")
  return (data:gsub(".", function(x)
    if x == "=" then return "" end
    local bits, value = "", alphabet:find(x, 1, true) - 1
    for i = 6, 1, -1 do bits = bits .. (value % 2^i - value % 2^(i-1) > 0 and "1" or "0") end
    return bits
  end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
    if #x ~= 8 then return "" end
    local c = 0
    for i = 1, 8 do c = c + (x:sub(i,i) == "1" and 2^(8-i) or 0) end
    return string.char(c)
  end))
end

local function quote(s) return '"' .. s:gsub('"','\\"') .. '"' end
local function run_bridge(mode, data, docx)
  local command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' ..
    quote(BRIDGE) .. ' -Mode ' .. mode .. ' -DataPath ' .. quote(data) ..
    ' -DocxPath ' .. quote(docx)
  local exit_code, output = r.ExecProcess(command, 120000)
  if tonumber(exit_code) ~= 0 then
    r.ShowConsoleMsg(
      "[ReaTitles ERROR] Word " .. mode .. " failed.\n" ..
      tostring(output or "") .. "\n")
    return false
  end
  return true
end

local function notes(item)
  local _, value = r.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
  return value or ""
end

local function subtitle_items()
  local result = {}
  for ti = 0, r.CountTracks(0)-1 do
    local track = r.GetTrack(0, ti)
    local _, name = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if name == "Subtitles" then
      for i = 0, r.CountTrackMediaItems(track)-1 do
        local item = r.GetTrackMediaItem(track, i)
        if notes(item) ~= "" then result[#result+1] = item end
      end
    end
  end
  table.sort(result, function(a,b)
    return r.GetMediaItemInfo_Value(a,"D_POSITION") < r.GetMediaItemInfo_Value(b,"D_POSITION")
  end)
  return result
end

local function grouped(item)
  local out, gid = {}, r.GetMediaItemInfo_Value(item, "I_GROUPID")
  if gid <= 0 then return out end
  for ti=0,r.CountTracks(0)-1 do
    local tr=r.GetTrack(0,ti)
    for i=0,r.CountTrackMediaItems(tr)-1 do
      local it=r.GetTrackMediaItem(tr,i)
      if it ~= item and r.GetMediaItemInfo_Value(it,"I_GROUPID")==gid then out[#out+1]=it end
    end
  end
  return out
end

local function choose_file(save)
  if save and r.APIExists("JS_Dialog_BrowseForSaveFile") then
    local ok, path = r.JS_Dialog_BrowseForSaveFile("Export Word review", "", "ReaTitles_review.docx", "Word document (*.docx)\0*.docx\0")
    return ok and path or nil
  elseif not save then
    local ok, path = r.GetUserFileNameForRead("", "Import edited Word document", "docx")
    return ok and path or nil
  end
  local _, project = r.EnumProjects(-1, "")
  return (project:match("^(.*[\\/])") or SCRIPT_DIR) .. "ReaTitles_review.docx"
end

local function export_word()
  local items = subtitle_items()
  if #items == 0 then return r.ShowMessageBox("No subtitle items found.", "ReaTitles Word", 0) end
  local path = choose_file(true); if not path then return end
  local data = SCRIPT_DIR .. "rt_word_export.tsv"
  local file = assert(io.open(data, "wb"))
  r.Undo_BeginBlock()
  for _, item in ipairs(items) do
    local _, id = r.GetSetMediaItemInfo_String(item, ID_KEY, "", false)
    if id == "" then
      id = r.genGuid():gsub("[{}%-]","")
      r.GetSetMediaItemInfo_String(item, ID_KEY, id, true)
    end
    local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local time = r.format_timestr_pos(pos, "", 0)
    local color = r.GetMediaItemInfo_Value(item, "I_CUSTOMCOLOR")
    local rgb = ""
    if color ~= 0 then
      local red,green,blue=r.ColorFromNative(color); rgb=red..","..green..","..blue
    end
    file:write(id,"\t",time,"\t",b64encode(notes(item)),"\t",rgb,"\n")
  end
  file:close()
  r.Undo_EndBlock("ReaTitles: Assign Word document IDs", -1)
  local ok = run_bridge("export", data, path)
  os.remove(data)
  r.ShowMessageBox(ok and ("Word document created:\n"..path) or "Word export failed.", "ReaTitles Word", 0)
end

local function import_word()
  local path = choose_file(false); if not path then return end
  local data = SCRIPT_DIR .. "rt_word_import.tsv"
  if not run_bridge("import", data, path) then
    return r.ShowMessageBox("Word import failed.", "ReaTitles Word", 0)
  end
  local rows = {}
  for line in io.lines(data) do
    local id, encoded, rgb = line:match("^([^\t]+)\t([^\t]*)\t?(.*)$")
    if id then rows[#rows+1] = {id=id,text=b64decode(encoded),rgb=rgb} end
  end
  os.remove(data)
  local items, by_id, original_index = subtitle_items(), {}, {}
  for i,item in ipairs(items) do
    local _,id=r.GetSetMediaItemInfo_String(item,ID_KEY,"",false)
    if id~="" then by_id[id]=item; original_index[id]=i end
  end
  local kept, present = {}, {}
  for _,row in ipairs(rows) do
    if by_id[row.id] then kept[#kept+1]={row=row,item=by_id[row.id]}; present[row.id]=true end
  end
  if #kept == 0 then return r.ShowMessageBox("No ReaTitles IDs found in this document.", "ReaTitles Word", 0) end

  local start = math.huge
  for _,item in ipairs(items) do start=math.min(start,r.GetMediaItemInfo_Value(item,"D_POSITION")) end
  r.Undo_BeginBlock(); r.PreventUIRefresh(1)
  for _,item in ipairs(items) do
    local _,id=r.GetSetMediaItemInfo_String(item,ID_KEY,"",false)
    if id~="" and not present[id] then
      for _,other in ipairs(grouped(item)) do r.DeleteTrackMediaItem(r.GetMediaItem_Track(other),other) end
      r.DeleteTrackMediaItem(r.GetMediaItem_Track(item),item)
    end
  end
  local cursor=start
  for new_index,entry in ipairs(kept) do
    local item,row=entry.item,entry.row
    local old=r.GetMediaItemInfo_Value(item,"D_POSITION")
    local delta=cursor-old
    r.GetSetMediaItemInfo_String(item,"P_NOTES",row.text,true)
    r.SetMediaItemPosition(item,cursor,false)
    local color=0
    local rr,gg,bb=row.rgb:match("^(%d+),(%d+),(%d+)$")
    if rr then color=r.ColorToNative(tonumber(rr),tonumber(gg),tonumber(bb)) | 0x1000000 end
    r.SetMediaItemInfo_Value(item,"I_CUSTOMCOLOR",color)
    for _,other in ipairs(grouped(item)) do
      r.SetMediaItemPosition(other,r.GetMediaItemInfo_Value(other,"D_POSITION")+delta,false)
      r.SetMediaItemInfo_Value(other,"I_CUSTOMCOLOR",color)
    end
    if new_index > 1 then
      local previous_id = kept[new_index-1].row.id
      local previous_original = original_index[previous_id]
      local current_original = original_index[row.id]
      if current_original ~= previous_original + 1 then
        local label = previous_original < current_original and "УДАЛ" or "ПЕРЕНОС"
        r.AddProjectMarker2(0,false,cursor,0,label,-1,0)
      end
    end
    cursor=cursor+r.GetMediaItemInfo_Value(item,"D_LENGTH")
  end
  r.PreventUIRefresh(-1); r.UpdateArrange()
  r.Undo_EndBlock("ReaTitles: Apply edited Word document", -1)
  r.ShowMessageBox("Word edits applied.", "ReaTitles Word", 0)
end

local answer=r.ShowMessageBox("Yes: export Word document\nNo: import edited Word document", "ReaTitles Word", 3)
if answer==6 then export_word() elseif answer==7 then import_word() end
