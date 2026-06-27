-- @description Prompter
-- @author Chirick, ReaTitles contributors
-- @version 1.3.3
-- @changelog
--   + Magnetic phrase editing, offline transcription and Word review round-trip
-- @link https://github.com/uncleosmixing/ReaTitles
-- @provides
--   [main] ch_import_text_items_from_sub.lua
--   [main] rt_transcribe_audio.lua
--   [main] rt_smart_split.lua
--   [nomain] ch_SubOverlay.lua
--   [nomain] rt_subtitle_model.lua
--   [nomain] rt_whisper_transcribe.py
--   [nomain] rt_word_bridge.ps1
--   [nomain] rt_word_roundtrip.lua
-- @donation https://patreon.com/chirick
-- @about
--   # Prompter
--   
--   Prompter for working with subtitles (regions/items) in REAPER
--   
--   ## Features
--   * Shows regions or text items as a scrollable list
--   * Automatically highlights current line based on playback position
--   * Quick navigation by clicking on a line (+ copies text to clipboard)
--   * Customizable fonts, colors and sizes for regions and items separately
--   * Search with highlighted results
--   * "All elements" mode - combines regions and items in one timeline-sorted list
--   * Smooth scrolling and current line magnification
--   ## Requirements
--   * ReaImGui (install via ReaPack)
        
--[[TODO:
-- Save commandID in ExtState]]

if not reaper.ImGui_CreateContext then
    reaper.ShowMessageBox(
        "Missing dependency: ReaImGui.\n\n" ..
        "Install ReaImGui through ReaPack, then restart REAPER.\n" ..
        "Install it and run Prompter again.",
        "ReaTitles dependency error", 0)
    return
end

local script_source = (debug.getinfo(1, "S") or {}).source or ""
local script_dir = script_source:match("^@(.+[\\/])") or ""
local model_ok, subtitle_model =
    pcall(dofile, script_dir .. "rt_subtitle_model.lua")
if not model_ok then
    reaper.ShowMessageBox(
        "ReaTitles installation is incomplete: rt_subtitle_model.lua is missing.\n\n" ..
        tostring(subtitle_model),
        "ReaTitles dependency error", 0)
    return
end

local debug_mode = false
local TITLE     = "Chirick Prompter"
local SETTINGS  = TITLE
local ctx       = reaper.ImGui_CreateContext(TITLE)
local proj_name = reaper.GetProjectName(0)
local proj_id   = reaper.EnumProjects(-1)
local proj_guid = tostring(proj_name .. tostring(proj_id):sub(-6))
local languages = {"EN", "DE", "FR", "RU", "UK"}
local lang = "EN"

-- Table for caching strings of the current language
local str = {}

local i18n = {
    EN = {
        i_import    = "Import",
        i_overlay   = "Overlay",
        i_sources   = "No sources",
        i_empty     = "Load regions or text items",
        -- Source names
        i_regions = "regions",
        i_all_items = "all items",
        -- Tooltips for fonts
        t_region_font = "Font for displaying region lines",
        t_region_scale = "Region font size",
        t_item_font = "Font for displaying item lines",
        t_item_scale = "Item font size",
        -- Tooltips for central scaling
        t_central_scale_title = "Enable current line magnification\nRecommended to use with smooth scrolling",
        t_central_scale = "Magnification factor for the current highlighted line",
        -- Tooltips for functions
        t_smooth_scroll = "Enable smooth scrolling when jumping to the current line",
        t_auto_wrap = "Automatic word wrapping for long lines",
        t_ignore_newlines = "Ignore line break characters \\n",
        t_auto_update = "Automatically update lists when project changes",
        t_show_tooltips = "Show tooltips on hover",
        -- Context menu items - headers
        c_regions = "Regions:",
        c_items = "Items:",
        -- Context menu items - functions
        c_central_scale = "Current line scaling",
        c_smooth_scroll = "Smooth scrolling",
        c_auto_wrap = "Word wrapping",
        c_ignore_newlines = "Ignore line breaks",
        c_auto_update = "Auto-update",
        c_show_tooltips = "Tooltips",
        c_autostart_reaper = "Autostart on REAPER",
        t_autostart_reaper = "Automatically launch Prompter when REAPER starts",
        -- Context menu items - colors
        c_region_color = "Regions",
        c_region_highlight = "Current region",
        c_item_color = "Items",
        c_item_highlight = "Current item",
        c_search_highlight = "Search highlight"
    },
    DE = {
        i_import    = "Import",
        i_overlay   = "Überlagerung",
        i_sources   = "Keine Quellen",
        i_empty     = "Laden Sie Regionen oder Textelemente",
        -- Quellennamen
        i_regions = "Regionen",
        i_all_items = "alle Elemente",
        -- Tooltips für Schriftarten
        t_region_font = "Schriftart zum Anzeigen von Regionszeilen",
        t_region_scale = "Schriftgröße für Regionen",
        t_item_font = "Schriftart zum Anzeigen von Elementzeilen",
        t_item_scale = "Schriftgröße für Elemente",
        -- Tooltips für zentrale Skalierung
        t_central_scale_title = "Vergrößerung der aktuellen Zeile aktivieren\nWird empfohlen, mit sanftem Scrollen zu verwenden",
        t_central_scale = "Vergrößerungsfaktor für die aktuell markierte Zeile",
        -- Tooltips für Funktionen
        t_smooth_scroll = "Sanftes Scrollen beim Wechsel zur aktuellen Zeile aktivieren",
        t_auto_wrap = "Automatisches Umbruch für lange Zeilen",
        t_ignore_newlines = "Zeilenumbruchzeichen ignorieren \\n",
        t_auto_update = "Listen automatisch aktualisieren, wenn sich das Projekt ändert",
        t_show_tooltips = "Tooltips beim Hovern anzeigen",
        -- Kontextmenü-Einträge - Kopfzeilen
        c_regions = "Regionen:",
        c_items = "Elemente:",
        -- Kontextmenü-Einträge - Funktionen
        c_central_scale = "Skalierung der aktuellen Zeile",
        c_smooth_scroll = "Sanftes Scrollen",
        c_auto_wrap = "Zeilenumbruch",
        c_ignore_newlines = "Zeilenumbrüche ignorieren",
        c_auto_update = "Automatische Aktualisierung",
        c_show_tooltips = "Tooltips",
        c_autostart_reaper = "Autostart bei REAPER",
        t_autostart_reaper = "Prompter automatisch starten, wenn REAPER startet",
        -- Kontextmenü-Einträge - Farben
        c_region_color = "Regionen",
        c_region_highlight = "Aktuelle Region",
        c_item_color = "Elemente",
        c_item_highlight = "Aktuelles Element",
        c_search_highlight = "Suchmarkierung"
    },
    FR = {
        i_import    = "Importer",
        i_overlay   = "Superposé",
        i_sources   = "Pas de sources",
        i_empty     = "Chargez des régions ou des éléments de texte",
        -- Noms des sources
        i_regions = "régions",
        i_all_items = "tous les éléments",
        -- Info-bulles pour les polices
        t_region_font = "Police pour afficher les lignes de région",
        t_region_scale = "Taille de la police des régions",
        t_item_font = "Police pour afficher les lignes d'éléments",
        t_item_scale = "Taille de la police des éléments",
        -- Info-bulles pour la mise à l'échelle centrale
        t_central_scale_title = "Activer l'agrandissement de la ligne actuelle\nRecommandé d'utiliser avec le défilement fluide",
        t_central_scale = "Facteur d'agrandissement de la ligne actuellement surlignée",
        -- Info-bulles pour les fonctions
        t_smooth_scroll = "Activer le défilement fluide lors du passage à la ligne actuelle",
        t_auto_wrap = "Renvoi automatique à la ligne pour les lignes longues",
        t_ignore_newlines = "Ignorer les caractères de saut de ligne \\n",
        t_auto_update = "Mettre à jour automatiquement les listes lors de modifications du projet",
        t_show_tooltips = "Afficher les info-bulles au survol",
        -- Éléments du menu contextuel - En-têtes
        c_regions = "Régions:",
        c_items = "Éléments:",
        -- Éléments du menu contextuel - Fonctions
        c_central_scale = "Mise à l'échelle de la ligne actuelle",
        c_smooth_scroll = "Défilement fluide",
        c_auto_wrap = "Retour à la ligne",
        c_ignore_newlines = "Ignorer les sauts de ligne",
        c_auto_update = "Mise à jour automatique",
        c_show_tooltips = "Info-bulles",
        c_autostart_reaper = "Démarrage auto avec REAPER",
        t_autostart_reaper = "Lancer automatiquement Prompter au démarrage de REAPER",
        -- Éléments du menu contextuel - Couleurs
        c_region_color = "Régions",
        c_region_highlight = "Région actuelle",
        c_item_color = "Éléments",
        c_item_highlight = "Élément actuel",
        c_search_highlight = "Mise en évidence de la recherche"
    },
    RU = {
        i_import    = "Импорт",
        i_overlay   = "Оверлей",
        i_sources   = "Нет источников",
        i_empty     = "Подгрузите регионы или текстовые итемы",
        -- Названия источников
        i_regions = "регионы",
        i_all_items = "все элементы",
        -- Тултипы для шрифтов
        t_region_font = "Шрифт для отрисовки строк регионов",
        t_region_scale = "Размер шрифта регионов",
        t_item_font = "Шрифт для отрисовки строк итемов",
        t_item_scale = "Размер шрифта итемов",
        -- Тултипы для центрального масштаба
        t_central_scale_title = "Включить увеличение текущей подсвеченной строки\nРекомендуется использовать в связке с плавным скроллом",
        t_central_scale = "Коэффициент увеличения текущей подсвеченной строки",
        -- Тултипы для функций
        t_smooth_scroll = "Включить плавный скролл при переходе к текущей строке",
        t_auto_wrap = "Автоматический перенос длинных строк",
        t_ignore_newlines = "Игнорировать символы переноса строки \\n",
        t_auto_update = "Автоматически обновлять списки при изменении проекта",
        t_show_tooltips = "Показывать подсказки при наведении",
        -- Пункты контекстного меню - заголовки
        c_regions = "Регионы:",
        c_items = "Итемы:",
        -- Пункты контекстного меню - функции
        c_central_scale = "Скейл текущей строки",
        c_smooth_scroll = "Плавный скролл",
        c_auto_wrap = "Автоперенос",
        c_ignore_newlines = "Игнорировать подстроки",
        c_auto_update = "Автообновление",
        c_show_tooltips = "Подсказки",
        c_autostart_reaper = "Автозапуск с REAPER",
        t_autostart_reaper = "Автоматически запускать Prompter при старте REAPER",
        -- Пункты контекстного меню - цвета
        c_region_color = "Регионы",
        c_region_highlight = "Текущий регион",
        c_item_color = "Итемы",
        c_item_highlight = "Текущий итем",
        c_search_highlight = "Подсветка поиска"
    },
    UK = {
        i_import    = "Імпорт",
        i_overlay   = "Оверлей",
        i_sources   = "Немає джерел",
        i_empty     = "Завантажте регіони або текстові елементи",
        -- Назви джерел
        i_regions = "регіони",
        i_all_items = "всі елементи",
        -- Підказки для шрифтів
        t_region_font = "Шрифт для відображення рядків регіонів",
        t_region_scale = "Розмір шрифту регіонів",
        t_item_font = "Шрифт для відображення рядків елементів",
        t_item_scale = "Розмір шрифту елементів",
        -- Підказки для центрального масштабування
        t_central_scale_title = "Увімкнути збільшення поточного рядка\nРекомендується використовувати разом з плавним прокручуванням",
        t_central_scale = "Коефіцієнт збільшення поточного виділеного рядка",
        -- Підказки для функцій
        t_smooth_scroll = "Увімкнути плавне прокручування при переході на поточний рядок",
        t_auto_wrap = "Автоматичний перенос довгих рядків",
        t_ignore_newlines = "Ігнорувати символи розриву рядка \\n",
        t_auto_update = "Автоматично оновлювати списки при змінах проекту",
        t_show_tooltips = "Показувати підказки при наведенні",
        -- Пункти контекстного меню - заголовки
        c_regions = "Регіони:",
        c_items = "Елементи:",
        -- Пункти контекстного меню - функції
        c_central_scale = "Масштабування поточного рядка",
        c_smooth_scroll = "Плавне прокручування",
        c_auto_wrap = "Перенос рядків",
        c_ignore_newlines = "Ігнорувати розриви рядків",
        c_auto_update = "Автооновлення",
        c_show_tooltips = "Підказки",
        c_autostart_reaper = "Автозапуск з REAPER",
        t_autostart_reaper = "Автоматично запускати Prompter при старті REAPER",
        -- Пункти контекстного меню - кольори
        c_region_color = "Регіони",
        c_region_highlight = "Поточний регіон",
        c_item_color = "Елементи",
        c_item_highlight = "Поточний елемент",
        c_search_highlight = "Підсвітлення пошуку"
    }
}

-- time
local scroll_delay = 0.5
local hovered_time = 0
local target_scroll_y = nil
local last_highlighted_idx = nil
local last_scroll_source = nil
local last_central_y = nil  -- to track position changes
local central_y = nil  -- position of central element
local hours_enabled = false

-- caching
local _, _, last_CountRegions = reaper.CountProjectMarkers(0)
local cached_pos, cached_source_guid, cached_source_idx, cached_line_idx = nil, nil, nil, nil
local last_text_items_count = 0
local last_proj_guid = proj_guid
local last_ProjectStateChangeCount = 0
local last_CountTracks = 0
local last_BPM = reaper.Master_GetTempo()

-- UI state
local want_context_menu = false
local window_hovered = false

-- UI dimensions
local ui_dimensions = {
    time_width = 0,
    space_width = 0,
    win_width = 0,
    win_height = 0
}

-- project data
local cur_regions = {}
local cur_items_by_track = {}
local combo_sources = {}

-- source indices
local source_idx = 1  -- index of the source in the combo_sources list
local source_guid = nil   -- unique identifier of the source (e.g., "regions" or "items_<track_guid>")    

-- cache for combined list
local combined_items_cache = nil  -- cached combined list
local combined_cache_valid = false  -- cache validity flag    

-- ========= Fonts =========
local font_names = {
    "Segoe UI","Roboto","Arial","Calibri","Tahoma","Verdana",
    "Cambria","CooperMediumC BT","Georgia","Times New Roman",
    "Consolas","Courier New"
}

local BASE_PT = 14
local fonts = {}
for i, name in ipairs(font_names) do
    local f = reaper.ImGui_CreateFont(name, BASE_PT)
    fonts[i] = f
    reaper.ImGui_Attach(ctx, f)
end

-- UI font (take the first one by default, can be customized in settings)
local ui_font   = fonts[1]
local ui_scale  = 14

-- Font settings for different types of elements
local font_settings = {
    region = {
        idx = 1,
        scale = ui_scale,
        font = fonts[1]
    },
    item = {
        idx = 1,
        scale = ui_scale,
        font = fonts[1]
    }
}
local central_scale = 1.2
local central_scale_enabled = false
local auto_wrap_enabled = true      -- auto-wrap long lines
local ignore_newlines   = false     -- replace \n with spaces
local autostart_on_reaper = false   -- auto-start Prompter on REAPER start

-- colors (default values, can be customized in settings)
local color_settings = {
    region = {
        normal = 0xCCCCCCFF,
        highlight = 0x00E5B4FF
    },
    item = {
        normal = 0x999999FF,
        highlight = 0x00E5B4FF
    },
    search_highlight = 0xFFD166FF
}
local search = ""  -- search string

-- functions
local smooth_scroll_enabled = false
local scroll_speed = 0.05
local auto_update_enabled = true

-- Theme colors
local theme = {
    bg        = 0x141420FF,
    child     = 0x111120FF,
    text      = 0xCCCCCCFF,
    dim       = 0x666677FF,
    border    = 0x222235FF,
    accent    = 0x00E5B4FF,
    accent2   = 0x3B82F6FF,
    hover     = 0x1C1C30FF,
    active    = 0x252540FF,
    separator = 0x1A1A2EFF,
    sb_bg     = 0x111120FF,
    sb_grab   = 0x2A2A40FF,
    sb_hov    = 0x3A3A55FF,
    sb_act    = 0x4A4A6AFF,
}

-- Inline editing state
local editing_idx = nil       -- index of item being edited (nil = none)
local edit_buf = ""           -- text buffer for editing
local edit_focus_pending = false
local edit_had_focus = false

-- Drag & drop state
local drag_source_idx = nil   -- index of item being dragged
local drag_start_y = nil      -- Y position where drag started (screen coords)
local drag_offset_y = nil     -- mouse offset within the row
local drag_drop_idx = nil     -- target index for drop
local drag_alpha = 0.0        -- animation alpha for ghost

-- tooltips
local show_tooltips    = true
local tooltip_delay    = 0.5
local tooltip_state    = {}  -- table of states (keyed by tooltip text)


-- 🚀 Управление автозапуском через __startup.lua
local STARTUP_MARKER_BEGIN = "-- [CHIRICK_PROMPTER_AUTOSTART_BEGIN] DO NOT EDIT THIS BLOCK"
local STARTUP_MARKER_END = "-- [CHIRICK_PROMPTER_AUTOSTART_END]"

-- get stable script identifier (and numeric ID if needed)
local function get_script_command_id()
    local _, _, _, scriptID = reaper.get_action_context()
    local named = reaper.ReverseNamedCommandLookup(scriptID) or ""
    if named ~= "" and named:sub(1, 1) ~= "_" then named = "_" .. named end
    return named
end

local function manage_startup_autostart(enable)
    local startup_path = reaper.GetResourcePath() .. "/Scripts/__startup.lua"
    
    -- Read before opening for writing: opening with "w" here would erase the
    -- user's complete startup script.
    local content = ""
    local reader = io.open(startup_path, "r")
    if reader then
        content = reader:read("*all") or ""
        reader:close()
    end

    -- Look for our block between the markers
    local block_start = content:find(STARTUP_MARKER_BEGIN, 1, true)
    local block_end = content:find(STARTUP_MARKER_END, 1, true)
    
    if enable then
        -- Get stable script identifier
        local scriptID = get_script_command_id()
        
        -- Add the block if it doesn't exist
        if not block_start and scriptID then
            local new_block = string.format([[

            -- [CHIRICK_PROMPTER_AUTOSTART_BEGIN] DO NOT EDIT THIS BLOCK
            if reaper.GetExtState("Chirick Prompter", "autostart_on_reaper") == "true" then
                reaper.Main_OnCommand(reaper.NamedCommandLookup("%s"), 0)
            end
            -- [CHIRICK_PROMPTER_AUTOSTART_END]
            ]], scriptID)
            content = content .. new_block
        end
    else
        -- Remove the block if it exists
        if block_start and block_end then
            local before = content:sub(1, block_start - 1)
            local after = content:sub(block_end + #STARTUP_MARKER_END)
            content = before .. after
        end
    end
    local file, err = io.open(startup_path, "w")
    if not file then
        reaper.ShowMessageBox(
            "Cannot update REAPER startup script:\n" .. tostring(err or startup_path),
            TITLE, 0)
        return false
    end
    file:write(content)
    file:close()
    return true
end

-- 🎬 Start overlay helper function
-- 💾 Save/load settings
local function save_settings()
    reaper.SetExtState(SETTINGS, "region_font_idx",   tostring(font_settings.region.idx), true)
    reaper.SetExtState(SETTINGS, "region_scale", tostring(font_settings.region.scale), true)
    reaper.SetExtState(SETTINGS, "item_font_idx",     tostring(font_settings.item.idx), true)
    reaper.SetExtState(SETTINGS, "item_scale",   tostring(font_settings.item.scale), true)
    reaper.SetExtState(SETTINGS, "central_scale", tostring(central_scale), true)
    reaper.SetExtState(SETTINGS, "central_scale_enabled", tostring(central_scale_enabled), true)
    reaper.SetExtState(SETTINGS, "region_color",     string.format("%08X", color_settings.region.normal), true)
    reaper.SetExtState(SETTINGS, "region_highlight", string.format("%08X", color_settings.region.highlight), true)
    reaper.SetExtState(SETTINGS, "item_color",       string.format("%08X", color_settings.item.normal), true)
    reaper.SetExtState(SETTINGS, "item_highlight",   string.format("%08X", color_settings.item.highlight), true)
    reaper.SetExtState(SETTINGS, "search_highlight", string.format("%08X", color_settings.search_highlight), true)
    reaper.SetExtState(SETTINGS, "smooth_scroll_enabled", tostring(smooth_scroll_enabled), true)
    reaper.SetExtState(SETTINGS, "show_tooltips",    tostring(show_tooltips), true)
    reaper.SetExtState(SETTINGS, "auto_wrap_enabled", tostring(auto_wrap_enabled), true)
    reaper.SetExtState(SETTINGS, "ignore_newlines",   tostring(ignore_newlines), true)
    reaper.SetExtState(SETTINGS, "time_width",   tostring(ui_dimensions.time_width), true)
    reaper.SetExtState(SETTINGS, "space_width",   tostring(ui_dimensions.space_width), true)
    reaper.SetExtState(SETTINGS, "auto_update_enabled", tostring(auto_update_enabled), true)
    reaper.SetExtState(SETTINGS, "lang", lang, true)
    reaper.SetExtState(SETTINGS, "autostart_on_reaper", tostring(autostart_on_reaper), true)

    -- Save the selected source to the project settings
    if combo_sources[source_idx] then
        reaper.SetProjExtState(0, SETTINGS, "source_guid", combo_sources[source_idx].guid)
    end
end

local function load_settings()
    local function read_bool(name, default_true_means_when_missing)
        local v = reaper.GetExtState(SETTINGS, name)
        if v == "" then
            return default_true_means_when_missing and true or false
        end
        return (v == "true")
    end

    local function read_num(name, fallback)
        local v = reaper.GetExtState(SETTINGS, name)
        if v == "" then return fallback end
        local n = tonumber(v)
        return n or fallback
    end

    local function read_color(name, fallback)
        local v = reaper.GetExtState(SETTINGS, name)
        if v == "" then return fallback end
        return tonumber(v, 16) or fallback
    end

    font_settings.region.idx   = math.max(1, math.min(#font_names, read_num("region_font_idx", font_settings.region.idx)))
    font_settings.item.idx     = math.max(1, math.min(#font_names, read_num("item_font_idx", font_settings.item.idx)))
    font_settings.region.scale = math.max(10, math.min(100, read_num("region_scale", font_settings.region.scale)))
    font_settings.item.scale   = math.max(10, math.min(100, read_num("item_scale", font_settings.item.scale)))
    
    -- Update font objects
    font_settings.region.font = fonts[font_settings.region.idx]
    font_settings.item.font = fonts[font_settings.item.idx]
    central_scale = math.max(1.0, math.min(2.5, read_num("central_scale", central_scale)))
    central_scale_enabled = read_bool("central_scale_enabled", central_scale_enabled)
    color_settings.region.normal     = read_color("region_color",     color_settings.region.normal)
    color_settings.region.highlight = read_color("region_highlight", color_settings.region.highlight)
    color_settings.item.normal       = read_color("item_color",       color_settings.item.normal)
    color_settings.item.highlight   = read_color("item_highlight",   color_settings.item.highlight)
    color_settings.search_highlight = read_color("search_highlight", color_settings.search_highlight)
    smooth_scroll_enabled = read_bool("smooth_scroll_enabled", smooth_scroll_enabled)
    show_tooltips    = read_bool("show_tooltips", true)
    auto_wrap_enabled = read_bool("auto_wrap_enabled", auto_wrap_enabled)
    ignore_newlines = read_bool("ignore_newlines", ignore_newlines)
    ui_dimensions.time_width = read_num("time_width", ui_dimensions.time_width)
    ui_dimensions.space_width = read_num("space_width", ui_dimensions.space_width)
    auto_update_enabled = read_bool("auto_update_enabled", auto_update_enabled)
    local stored_lang = reaper.GetExtState(SETTINGS, "lang")
    if stored_lang ~= "" then
        lang = stored_lang
    end
    -- Load the selected source from the project settings
    local retval, local_source_guid = reaper.GetProjExtState(0, SETTINGS, "source_guid")
    if retval then
        source_guid = local_source_guid
    end
    
    -- Load the setting for autostarting Prompter on REAPER startup
    autostart_on_reaper = read_bool("autostart_on_reaper", false)
    
end


-- 🔧 Low-level utilities
local function utf8lower(str)
    -- Correct lowercase conversion (Russian/Latin)
    local map = {
        -- Russian
        ["А"]="а",["Б"]="б",["В"]="в",["Г"]="г",["Д"]="д",["Е"]="е",["Ё"]="е",
        ["Ж"]="ж",["З"]="з",["И"]="и",["Й"]="й",["К"]="к",["Л"]="л",["М"]="м",
        ["Н"]="н",["О"]="о",["П"]="п",["Р"]="р",["С"]="с",["Т"]="т",["У"]="у",
        ["Ф"]="ф",["Х"]="х",["Ц"]="ц",["Ч"]="ч",["Ш"]="ш",["Щ"]="щ",["Ъ"]="ъ",
        ["Ы"]="ы",["Ь"]="ь",["Э"]="э",["Ю"]="ю",["Я"]="я",
        
        -- additional replacements for search
        ["ё"]="е",  -- lowercase ё is also transliterated to е

        -- Ukrainian (added)
        ["І"]="і",["I"]="і",["i"]="і", -- U+0406 → U+0456
        ["Ї"]="ї",
        ["Є"]="є",
        ["Ґ"]="ґ",
    }
    return (tostring(str or ""):gsub("[%z\1-\127\194-\244][\128-\191]*", function(c)
        return map[c] or c:lower()
    end))
end

local function format_time(sec)
    -- Use REAPER's own time formatter. Mode 0 follows the project's absolute
    -- timeline time (including project start offset) with millisecond precision.
    local value = reaper.format_timestr_pos(tonumber(sec) or 0, "", 0)
    return " " .. tostring(value or "0:00.000") .. " "
end

local function calculate_time_width()
    local sc = central_scale_enabled and central_scale or 1
    local src = combo_sources[source_idx]
    
    if src and src.kind == "regions" then
        reaper.ImGui_PushFont(ctx, font_settings.region.font, font_settings.region.scale*sc)
    elseif src and src.kind == "combined" then
        -- For combined source, use max scale between regions and items
        local max_scale = math.max(font_settings.region.scale, font_settings.item.scale) * sc
        reaper.ImGui_PushFont(ctx, font_settings.region.font, max_scale)
    else
        -- Default to items style
        reaper.ImGui_PushFont(ctx, font_settings.item.font, font_settings.item.scale*sc)
    end
    
    local start_sample = format_time(0)
    local end_sample = format_time(reaper.GetProjectLength(0))
    local start_width = reaper.ImGui_CalcTextSize(ctx, start_sample)
    local end_width = reaper.ImGui_CalcTextSize(ctx, end_sample)
    ui_dimensions.time_width = math.max(start_width, end_width) + 4
    ui_dimensions.space_width = reaper.ImGui_CalcTextSize(ctx, " ") -- separator space
    reaper.ImGui_PopFont(ctx)
end

-- 🔤 Load all strings for the current language (once when the language changes)
local function load_language_strings(lang_code)
    local trans = i18n[lang_code] or i18n["EN"]
    str.i_import         = trans.i_import
    str.i_overlay        = trans.i_overlay
    str.i_sources        = trans.i_sources
    str.i_empty          = trans.i_empty
    str.i_regions        = trans.i_regions
    str.i_all_items      = trans.i_all_items
    str.t_tooltips       = trans.t_tooltips
    str.c_contexts       = trans.c_contexts
    str.t_region_font    = trans.t_region_font
    str.t_region_scale   = trans.t_region_scale
    str.t_item_font      = trans.t_item_font
    str.t_item_scale     = trans.t_item_scale
    str.t_central_scale_title = trans.t_central_scale_title
    str.t_central_scale  = trans.t_central_scale
    str.t_smooth_scroll  = trans.t_smooth_scroll
    str.t_auto_wrap      = trans.t_auto_wrap
    str.t_ignore_newlines = trans.t_ignore_newlines
    str.t_auto_update    = trans.t_auto_update
    str.t_show_tooltips  = trans.t_show_tooltips
    str.c_regions        = trans.c_regions
    str.c_items          = trans.c_items
    str.c_central_scale  = trans.c_central_scale
    str.c_smooth_scroll  = trans.c_smooth_scroll
    str.c_auto_wrap      = trans.c_auto_wrap
    str.c_ignore_newlines = trans.c_ignore_newlines
    str.c_auto_update    = trans.c_auto_update
    str.c_show_tooltips  = trans.c_show_tooltips
    str.c_autostart_reaper = trans.c_autostart_reaper
    str.t_autostart_reaper = trans.t_autostart_reaper
    str.c_region_color   = trans.c_region_color
    str.c_region_highlight = trans.c_region_highlight
    str.c_item_color     = trans.c_item_color
    str.c_item_highlight = trans.c_item_highlight
    str.c_search_highlight = trans.c_search_highlight
end

-- 🔍 Search function
local function search_filter(items, search_query)
    if not search_query or search_query == "" then
        return items  -- If the search is empty, return all items
    end
    
    local filtered = {}
    local query_lower = utf8lower(search_query)
    
    for _, item in ipairs(items) do
        local found = false
        
        -- Search in the main text
        local item_text = item.name or ""
        local item_lower = utf8lower(item_text)
        if string.find(item_lower, query_lower, 1, true) then
            found = true
        end
        
        -- Search in the track name (if available)
        if not found and item.track_name then
            local track_lower = utf8lower(item.track_name)
            if string.find(track_lower, query_lower, 1, true) then
                found = true
            end
        end
        
        if found then
            filtered[#filtered+1] = item
        end
    end
    
    return filtered
end


-- 📊 Project work
local function collect_regions()
    cur_regions = {}

    local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
    local total = num_markers + num_regions

    for enum_i = 0, total - 1 do
        local _, isrgn, pos, rgnend, name, markrgnindex, color =
            reaper.EnumProjectMarkers3(0, enum_i)
        if isrgn then
            if ignore_newlines then name = string.gsub(name, "\n", " ") end
            cur_regions[#cur_regions+1] = {
                -- !!! сохраняем нативный индекс API
                api_idx    = markrgnindex,
                start_time = pos,
                end_time   = rgnend,
                start_str  = format_time(pos),
                end_str    = format_time(rgnend),
                name       = name or ("Region " .. tostring(markrgnindex)),
                color      = color,
                type       = "region"
            }
        end
    end
end

-- One-way migration from the old movement-sensitive absolute timestamps.
-- It never replaces non-empty P_NOTES. Empty notes are restored only when the
-- item's own word data yields unambiguous text.
local function migrate_legacy_word_timing()
    local plan = {}
    for t = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, t)
        for i = 0, reaper.CountTrackMediaItems(track) - 1 do
            local item = reaper.GetTrackMediaItem(track, i)
            if not reaper.GetActiveTake(item) then
                local legacy = subtitle_model.get_string(
                    item, subtitle_model.LEGACY_TIMING_KEY)
                local relative = subtitle_model.get_string(
                    item, subtitle_model.RELATIVE_TIMING_KEY)
                if legacy ~= "" or relative ~= "" then
                    local words = subtitle_model.get_relative_words(item, false)
                    local notes = subtitle_model.get_string(
                        item, subtitle_model.NOTES_KEY)
                    local repair_text = ""
                    if notes == "" and #words > 0 then
                        local item_length =
                            reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                        repair_text = subtitle_model.text_for_range(
                            words, 0, item_length)
                    end
                    if legacy ~= "" or repair_text ~= "" then
                        plan[#plan + 1] = {
                            item = item,
                            words = words,
                            migrate = legacy ~= "",
                            repair_text = repair_text,
                        }
                    end
                end
            end
        end
    end
    if #plan == 0 then return 0 end

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)
    local repaired = 0
    for _, entry in ipairs(plan) do
        if reaper.ValidatePtr(entry.item, "MediaItem*") then
            if entry.migrate and #entry.words > 0 then
                subtitle_model.set_relative_words(entry.item, entry.words)
            end
            if entry.repair_text ~= "" then
                subtitle_model.set_string(
                    entry.item, subtitle_model.NOTES_KEY, entry.repair_text)
                repaired = repaired + 1
            end
        end
    end
    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock(
        "ReaTitles: Migrate word timing and restore empty subtitles", -1)
    return repaired
end

local function collect_text_items()
    cur_items_by_track = {}
    local num_tracks = reaper.CountTracks(0)
    for t = 0, num_tracks-1 do
        local track = reaper.GetTrack(0, t)
        local _, track_name = reaper.GetTrackName(track)
        local track_guid = reaper.GetTrackGUID(track)
        
        -- Check if track is muted
        local is_muted = reaper.GetMediaTrackInfo_Value(track, "B_MUTE") == 1
        if is_muted then
            -- mark such track with flag
        end

        local items = {}
        local num_items = reaper.CountTrackMediaItems(track)
        for i = 0, num_items-1 do
            local it = reaper.GetTrackMediaItem(track, i)
            local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
            local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
            local _, notes = reaper.GetSetMediaItemInfo_String(it, "P_NOTES", "", false)
            if notes ~= "" then
                if ignore_newlines then notes = string.gsub(notes, "\n", " ") end
                items[#items+1] = {
                    start_time = pos,
                    end_time   = pos + len,
                    start_str  = format_time(pos),
                    end_str    = format_time(pos + len),
                    name       = notes,
                    track_name = track_name,
                    type       = "text_item",
                    item_ptr   = it,
                    group_id   = reaper.GetMediaItemInfo_Value(it, "I_GROUPID"),
                    custom_color = reaper.GetMediaItemInfo_Value(it, "I_CUSTOMCOLOR"),
                }
            end
        end

        -- Add track only if it has text items
        if #items > 0 then
            table.sort(items, function(a,b) return a.start_time < b.start_time end)
            
            cur_items_by_track[#cur_items_by_track+1] = {
                track_guid = track_guid,
                track_id   = track,
                track_name = track_name,
                items      = items,
                is_muted   = is_muted  -- flag for muted track
            }
        end
    end
end

-- Return all other items in the same REAPER group. Position-only matching is
-- intentionally avoided: it could select or delete unrelated video/MIDI items.
local function find_grouped_items(sub_item)
    local result = {}
    local boundary_matches = {}
    local same_group = {}
    if not sub_item or not reaper.ValidatePtr(sub_item, "MediaItem*") then
        return result
    end
    local group_id = reaper.GetMediaItemInfo_Value(sub_item, "I_GROUPID")
    local sub_start = reaper.GetMediaItemInfo_Value(sub_item, "D_POSITION")
    local sub_end = sub_start + reaper.GetMediaItemInfo_Value(sub_item, "D_LENGTH")
    local boundary_tolerance = 0.02
    for t = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, t)
        for i = 0, reaper.CountTrackMediaItems(track) - 1 do
            local it = reaper.GetTrackMediaItem(track, i)
            if it ~= sub_item and reaper.GetActiveTake(it) then
                local item_start = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
                local item_end = item_start + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
                if group_id > 0 and
                   reaper.GetMediaItemInfo_Value(it, "I_GROUPID") == group_id then
                    same_group[#same_group+1] = {
                        ptr = it,
                        score = math.abs(item_start - sub_start) +
                                math.abs(item_end - sub_end),
                    }
                end
                -- Native Split can leave several neighbouring phrase pairs with
                -- one group ID. Only media sharing this subtitle's boundaries
                -- belongs to this phrase; moving the whole ID causes overlaps.
                if math.abs(item_start - sub_start) <= boundary_tolerance and
                   math.abs(item_end - sub_end) <= boundary_tolerance then
                    if reaper.GetMediaItemInfo_Value(it, "I_GROUPID") == group_id then
                        result[#result+1] = it
                    else
                        boundary_matches[#boundary_matches+1] = it
                    end
                end
            end
        end
    end
    -- A properly created ReaTitles phrase owns one media item through a unique
    -- group ID. Keep that relationship even if an earlier failed move already
    -- shifted audio and subtitle to slightly different positions.
    if #same_group == 1 then
        return { same_group[1].ptr }
    end
    if #same_group > 1 then
        table.sort(same_group, function(a, b) return a.score < b.score end)
        -- Old/native splits can duplicate a group ID. In that case use only the
        -- closest media item; the reorder preflight prevents duplicate claims.
        return { same_group[1].ptr }
    end
    -- Repair mode for projects already damaged by native Split/group IDs:
    -- exact phrase boundaries are safer than moving nothing. Prefer explicit
    -- groups whenever at least one valid grouped media item exists.
    return (#result > 0) and result or boundary_matches
end

local function move_item_group(sub_item, new_pos)
    if not sub_item or not reaper.ValidatePtr(sub_item, "MediaItem*") then return end
    local old_pos = reaper.GetMediaItemInfo_Value(sub_item, "D_POSITION")
    local delta = new_pos - old_pos
    local grouped = find_grouped_items(sub_item)
    reaper.SetMediaItemPosition(sub_item, new_pos, false)
    for _, it in ipairs(grouped) do
        if reaper.ValidatePtr(it, "MediaItem*") then
            local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
            reaper.SetMediaItemPosition(it, pos + delta, false)
        end
    end
end

local function delete_item_group(sub_item)
    if not sub_item or not reaper.ValidatePtr(sub_item, "MediaItem*") then return false end
    local grouped = find_grouped_items(sub_item)
    for _, it in ipairs(grouped) do
        if reaper.ValidatePtr(it, "MediaItem*") then
            reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(it), it)
        end
    end
    reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(sub_item), sub_item)
    return true
end

local function delete_display_element(element)
    if not element then return false end
    if element.type == "region" and element.api_idx ~= nil then
        return reaper.DeleteProjectMarker(0, element.api_idx, true)
    end
    return delete_item_group(element.item_ptr)
end

local function save_element_text(element, text)
    if not element then return false end
    if element.type == "region" and element.api_idx ~= nil then
        return reaper.SetProjectMarker3(
            0, element.api_idx, true, element.start_time, element.end_time,
            text, element.color or 0)
    end
    if element.item_ptr and reaper.ValidatePtr(element.item_ptr, "MediaItem*") then
        reaper.GetSetMediaItemInfo_String(element.item_ptr, "P_NOTES", text, true)
        -- Manual text no longer has a trustworthy correspondence with the
        -- original Whisper words, so do not overwrite the edit on next scan.
        subtitle_model.set_string(
            element.item_ptr, subtitle_model.RELATIVE_TIMING_KEY, "")
        subtitle_model.set_string(
            element.item_ptr, subtitle_model.LEGACY_TIMING_KEY, "")
        subtitle_model.set_string(
            element.item_ptr, subtitle_model.TIMING_ANCHOR_KEY, "")
        subtitle_model.set_string(
            element.item_ptr, subtitle_model.TIMING_LENGTH_KEY, "")
        local take = reaper.GetActiveTake(element.item_ptr)
        if take then
            local short = text
            if #short > 40 then short = short:sub(1, 40) .. "..." end
            reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", short, true)
        end
        return true
    end
    return false
end

-- Select one item and every item explicitly grouped with it.
local function select_item_pair(sub_item)
    reaper.Main_OnCommand(40289, 0) -- Unselect all items
    if not sub_item or not reaper.ValidatePtr(sub_item, "MediaItem*") then return end
    reaper.SetMediaItemSelected(sub_item, true)
    for _, it in ipairs(find_grouped_items(sub_item)) do
        if reaper.ValidatePtr(it, "MediaItem*") then
            reaper.SetMediaItemSelected(it, true)
        end
    end
    reaper.UpdateArrange()
end

-- Magnetic insert, similar to an NLE:
--   * the dragged phrase is anchored at the destination phrase start;
--   * the complete left block is translated so its last edge touches the
--     dragged phrase start;
--   * the complete right block is translated so its first edge touches the
--     dragged phrase end;
--   * gaps inside each block are preserved;
--   * the hole left by the dragged phrase is collapsed.
-- Grouped media follows every subtitle by exactly the same delta.
local function reorder_item(src_idx, dst_idx)
    if src_idx == dst_idx or search ~= "" then return false end
    if not src or src.kind ~= "text_items" then return false end

    local entries = {}
    for _, item in ipairs(src.data or {}) do
        if item.item_ptr and reaper.ValidatePtr(item.item_ptr, "MediaItem*") then
            entries[#entries+1] = {
                item = item,
                ptr = item.item_ptr,
                pos = reaper.GetMediaItemInfo_Value(item.item_ptr, "D_POSITION"),
                len = reaper.GetMediaItemInfo_Value(item.item_ptr, "D_LENGTH"),
                orig_idx = #entries + 1,
                media = find_grouped_items(item.item_ptr),
            }
        end
    end
    if src_idx < 1 or src_idx > #entries or dst_idx < 1 or dst_idx > #entries then
        return false
    end

    local moved = entries[src_idx]
    local anchor_pos = entries[dst_idx].pos

    -- Original non-negative gaps. Existing overlaps are treated as zero gap so
    -- this operation also guarantees a non-overlapping result.
    local gaps = {}
    for i = 1, #entries - 1 do
        gaps[i] = math.max(0, entries[i+1].pos - (entries[i].pos + entries[i].len))
    end

    -- Remove the dragged phrase and build a clean base layout. When its former
    -- neighbours meet, retain only the gaps that surrounded it, not its length.
    local remaining = {}
    for i, entry in ipairs(entries) do
        if i ~= src_idx then remaining[#remaining+1] = entry end
    end
    if #remaining > 0 then
        remaining[1].base_pos = remaining[1].pos
        for i = 2, #remaining do
            local prev, cur = remaining[i-1], remaining[i]
            local preserved_gap = 0
            for gap_idx = prev.orig_idx, cur.orig_idx - 1 do
                preserved_gap = preserved_gap + (gaps[gap_idx] or 0)
            end
            cur.base_pos = prev.base_pos + prev.len + preserved_gap
        end
    end

    local new_order = {}
    for i, entry in ipairs(remaining) do new_order[i] = entry end
    table.insert(new_order, dst_idx, moved)

    local planned_positions = {}
    for i = 1, #new_order do
        local entry = new_order[i]
        if i < dst_idx then
            planned_positions[entry] = entry.base_pos
        elseif i == dst_idx then
            if dst_idx == 1 then
                planned_positions[entry] = entries[1].pos
            else
                local prev = new_order[i - 1]
                local gap = gaps[prev.orig_idx] or 0
                planned_positions[entry] = planned_positions[prev] + prev.len + gap
            end
        else
            local prev = new_order[i - 1]
            local gap
            if i - 1 == dst_idx then
                gap = gaps[moved.orig_idx] or 0
            else
                gap = entry.base_pos - (prev.base_pos + prev.len)
            end
            planned_positions[entry] = planned_positions[prev] + prev.len + gap
        end
    end

    -- REAPER can represent negative item positions, but a magnetic edit near
    -- project start should keep the whole construction on the visible timeline.
    local min_pos = math.huge
    for _, entry in ipairs(new_order) do
        min_pos = math.min(min_pos, planned_positions[entry] or entry.pos)
    end
    if min_pos < 0 then
        for _, entry in ipairs(new_order) do
            planned_positions[entry] = (planned_positions[entry] or entry.pos) - min_pos
        end
    end

    -- Hard safety checks: never touch the project if the calculated subtitle
    -- layout overlaps or one media item is ambiguously claimed by two phrases.
    for i = 1, #new_order - 1 do
        local current, following = new_order[i], new_order[i+1]
        if planned_positions[current] + current.len >
           planned_positions[following] + 0.000001 then
            reaper.ShowMessageBox(
                "Move cancelled: the calculated phrase layout overlaps.",
                TITLE, 0)
            return false
        end
    end
    local claimed_media = {}
    local media_plan = {}
    local affected_tracks = {}
    local sequence_start, sequence_end = math.huge, -math.huge
    local planned_sequence_start, planned_sequence_end = math.huge, -math.huge
    for _, entry in ipairs(entries) do
        sequence_start = math.min(sequence_start, entry.pos)
        sequence_end = math.max(sequence_end, entry.pos + entry.len)
        local planned = planned_positions[entry] or entry.pos
        planned_sequence_start = math.min(planned_sequence_start, planned)
        planned_sequence_end =
            math.max(planned_sequence_end, planned + entry.len)
    end
    for _, entry in ipairs(new_order) do
        for _, media_item in ipairs(entry.media) do
            if claimed_media[media_item] and claimed_media[media_item] ~= entry then
                reaper.ShowMessageBox(
                    "Move cancelled: one media item belongs to multiple subtitle phrases.\n" ..
                    "Repair the item groups before moving this phrase.",
                    TITLE, 0)
                return false
            end
            claimed_media[media_item] = entry
            local media_track = reaper.GetMediaItem_Track(media_item)
            affected_tracks[media_track] = true
            media_plan[#media_plan+1] = {
                ptr = media_item,
                track = media_track,
                lane = reaper.GetMediaItemInfo_Value(media_item, "I_FIXEDLANE"),
                -- Preserve the user's internal edit exactly. Reordering only
                -- translates the phrase unit; it must never resize or snap the
                -- media to manually adjusted subtitle boundaries.
                pos = reaper.GetMediaItemInfo_Value(media_item, "D_POSITION") +
                      (planned_positions[entry] - entry.pos),
                len = reaper.GetMediaItemInfo_Value(media_item, "D_LENGTH"),
                moved = true,
            }
        end
    end

    -- Include stationary media on the affected tracks. A stale silence fragment
    -- fully contained inside the subtitle sequence is debris from an older
    -- mismatched transcription cut. The aligned phrase blocks replace it.
    local orphan_media = {}
    for track in pairs(affected_tracks) do
        for i = 0, reaper.CountTrackMediaItems(track) - 1 do
            local media_item = reaper.GetTrackMediaItem(track, i)
            if reaper.GetActiveTake(media_item) and not claimed_media[media_item] then
                local item_pos =
                    reaper.GetMediaItemInfo_Value(media_item, "D_POSITION")
                local item_len =
                    reaper.GetMediaItemInfo_Value(media_item, "D_LENGTH")
                local item_end = item_pos + item_len
                local inside_old_sequence =
                    item_pos >= sequence_start - 0.000001 and
                    item_end <= sequence_end + 0.000001
                local overlaps_new_sequence =
                    item_end > planned_sequence_start + 0.000001 and
                    item_pos < planned_sequence_end - 0.000001
                if inside_old_sequence or overlaps_new_sequence then
                    orphan_media[#orphan_media+1] = media_item
                else
                    media_plan[#media_plan+1] = {
                        ptr = media_item,
                        track = track,
                        lane = reaper.GetMediaItemInfo_Value(media_item, "I_FIXEDLANE"),
                        pos = item_pos,
                        len = item_len,
                        moved = false,
                    }
                end
            end
        end
    end
    table.sort(media_plan, function(a, b)
        if a.track == b.track then
            if a.lane == b.lane then return a.pos < b.pos end
            return a.lane < b.lane
        end
        return tostring(a.track) < tostring(b.track)
    end)
    for i = 1, #media_plan - 1 do
        local a = media_plan[i]
        for j = i + 1, #media_plan do
            local b = media_plan[j]
            if b.track ~= a.track or b.lane ~= a.lane then break end
            if b.pos >= a.pos + a.len - 0.000001 then break end
            if a.moved or b.moved then
                reaper.ShowMessageBox(
                    "Move cancelled: audio items would overlap.\n" ..
                    "The project was not changed.",
                    TITLE, 0)
                return false
            end
        end
    end

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)
    local ok, err = xpcall(function()
        for _, orphan in ipairs(orphan_media) do
            if reaper.ValidatePtr(orphan, "MediaItem*") then
                reaper.DeleteTrackMediaItem(
                    reaper.GetMediaItem_Track(orphan), orphan)
            end
        end
        for _, entry in ipairs(new_order) do
            local new_pos = planned_positions[entry]
            if new_pos then
                local delta = new_pos - entry.pos
                reaper.SetMediaItemPosition(entry.ptr, new_pos, false)
                -- Use the immutable phrase snapshot collected before anything
                -- moved. Looking up groups here is unsafe: an earlier item may
                -- already occupy another phrase's old boundaries.
                for _, media_item in ipairs(entry.media) do
                    if reaper.ValidatePtr(media_item, "MediaItem*") then
                        local media_pos =
                            reaper.GetMediaItemInfo_Value(media_item, "D_POSITION")
                        reaper.SetMediaItemPosition(
                            media_item, media_pos + delta, false)
                    end
                end
            end
        end
    end, debug.traceback)
    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("ReaTitles: Reorder subtitle groups", -1)
    if not ok then
        reaper.ShowMessageBox("Could not reorder subtitle groups:\n" .. tostring(err), TITLE, 0)
    end
    return ok
end

local function create_combined_list()
    if combined_cache_valid and combined_items_cache then
        return combined_items_cache
    end
    
    local combined = {}
    
    -- Create mapping of sources to their order in combo list
    local source_order = {}
    local order = 1
    
    -- Regions are always first
    if #cur_regions > 0 then
        source_order["regions"] = order
        order = order + 1
    end
    
    -- Then tracks in order of addition
    for _, track_data in ipairs(cur_items_by_track or {}) do
        if not track_data.is_muted then
            local track_guid = track_data.track_guid
            source_order["items_" .. tostring(track_guid)] = order
            order = order + 1
        end
    end
    
    -- Add regions
    for _, region in ipairs(cur_regions or {}) do
        combined[#combined+1] = {
            start_time = region.start_time,
            end_time = region.end_time,
            start_str = region.start_str,
            end_str = region.end_str,
            name = region.name,
            type = "region",
            api_idx = region.api_idx,
            color = region.color,
            source_type = "regions",
            source_order = source_order["regions"] or 999
        }
    end
    
    -- Add items only from unmuted tracks
    for _, track_data in ipairs(cur_items_by_track or {}) do
        -- Skip muted tracks
        if not track_data.is_muted then
            local track_guid = track_data.track_guid
            local track_order = source_order["items_" .. tostring(track_guid)] or 999
            
            for _, item in ipairs(track_data.items or {}) do
                combined[#combined+1] = {
                    start_time = item.start_time,
                    end_time = item.end_time,
                    start_str = item.start_str,
                    end_str = item.end_str,
                    name = item.name,
                    track_name = item.track_name,
                    type = "text_item",
                    source_type = "text_items",
                    source_order = track_order,
                    item_ptr = item.item_ptr,
                    group_id = item.group_id,
                    custom_color = item.custom_color,
                }
            end
        end
    end
    
    -- Sort by start time, if equal - by source order in combo list
    table.sort(combined, function(a, b) 
        if a.start_time == b.start_time then
            -- If times are equal, use source order from combo list
            return a.source_order < b.source_order
        else
            return a.start_time < b.start_time
        end
    end)
    
    combined_items_cache = combined
    combined_cache_valid = true
    
    return combined
end

local function invalidate_combined_cache()
    combined_cache_valid = false
    combined_items_cache = nil
end

local function get_combo_list()
    combo_sources = {}

    -- Regions
    if #cur_regions > 0 then
        combo_sources[#combo_sources+1] = {
            guid = "regions",
            name = str.i_regions,
            kind = "regions",
            data = cur_regions
        }
    end

    -- Items by tracks (only unmuted tracks with items)
    for _, track_data in ipairs(cur_items_by_track) do
        local track_name = track_data.track_name
        local track_guid = track_data.track_guid
        local items_list = track_data.items
        local is_muted   = track_data.is_muted

        -- Show only unmuted tracks in combo list
        if not is_muted then
        local short_name = (#track_name > 9)
            and (string.sub(track_name, -9))
            or track_name

        combo_sources[#combo_sources+1] = {
            guid  = "items_" .. tostring(track_guid),
            name  = short_name,
            kind  = "text_items",
            track = track_name,  -- full name (for debugging)
            data  = items_list
        }
        end
    end

    -- Combined source (only if more than one source)
    if #combo_sources > 1 then
        local combined_data = create_combined_list()
        if #combined_data > 0 then
            combo_sources[#combo_sources+1] = {
                guid = "combined",
                name = str.i_all_items,
                kind = "combined",
                data = combined_data
            }
        end
    end

    -- Restore selected source or set first available
    if source_guid then
        local found = false
        for i, source in ipairs(combo_sources) do
            if source.guid == source_guid then 
                source_idx = i
                found = true
                break
            end
        end
        if not found then
            source_idx = 1
        end
    else
        source_idx = 1
    end

end

local function update()
    cached_pos, cached_source_guid, cached_source_idx, cached_line_idx =
        nil, nil, nil, nil
    collect_regions()
    collect_text_items()
    get_combo_list()
    calculate_time_width()
end

local function get_current_index(pos, source)
    if not source or not source.data or #source.data == 0 then return nil end

    -- quick exit by cache
    if cached_pos and cached_source_guid == source.guid and math.abs(pos - cached_pos) < 1e-9 then
        return cached_line_idx
    end

    local data = source.data
    local idx_list = {}  -- list of all central indices

    if source.kind == "combined" then
        -- For combined list, collect ALL elements that fall under cursor/playhead
        local elements_in_range = {}
        local closest_prev = nil
        local closest_prev_time = -math.huge
        
        for i = 1, #data do
            local r = data[i]
            -- Check if current position is in element range
            -- Half-open ranges prevent both neighbouring phrases becoming
            -- active on their shared edit boundary.
            if pos >= r.start_time and pos < r.end_time then
                elements_in_range[#elements_in_range + 1] = i
            elseif r.end_time < pos and r.end_time > closest_prev_time then
                -- Find closest previous elements
                if r.end_time == closest_prev_time then
                    -- Element with same end time - add to list
                    closest_prev[#closest_prev + 1] = i
                else
                    -- Found closer element - start new list
                    closest_prev_time = r.end_time
                    closest_prev = {i}
                end
            end
        end
        
        if #elements_in_range > 0 then
            -- Found elements under playhead - use them
            idx_list = elements_in_range
        elseif closest_prev then
            -- Playhead between elements - take all closest previous from all sources
            idx_list = closest_prev
        else
            -- Found nothing - take first element
            idx_list[1] = 1
        end
    else
        -- Regular logic for other sources - only one element
        local idx
        for i = 1, #data do
            if pos < data[i].start_time then
                idx = (i > 1) and (i-1) or 1
                break
            end
        end
        if not idx then idx = #data end
        idx_list[1] = idx
    end

    cached_pos, cached_source_guid, cached_line_idx = pos, source.guid, idx_list
    return idx_list
end

local function project_changed()
    proj_name = reaper.GetProjectName(0)
    proj_id   = reaper.EnumProjects(-1)
    proj_guid = tostring(proj_name .. tostring(proj_id):sub(-6))
    local ProjectStateChangeCount = reaper.GetProjectStateChangeCount(0)
    local CountTracks = reaper.CountTracks(0)
    local _, _, CountRegions = reaper.CountProjectMarkers(0)
    local text_items_count = 0

    if proj_guid ~= last_proj_guid then
        last_proj_guid = proj_guid
        load_settings()
        return true
    elseif ProjectStateChangeCount == last_ProjectStateChangeCount then
        return false
    end

    last_ProjectStateChangeCount = ProjectStateChangeCount
    if CountRegions ~= last_CountRegions then
        last_CountRegions = CountRegions
        return true
    end

    for _, track_data in ipairs(cur_items_by_track or {}) do
        local track_id = track_data.track_id
        -- Check if the track still exists
        if track_id and reaper.ValidatePtr(track_id, "MediaTrack*") then
            -- Check for mute status change
            local current_mute_status = reaper.GetMediaTrackInfo_Value(track_id, "B_MUTE") == 1
            local stored_mute_status = track_data.is_muted
            
            -- If the mute status has changed, it's a project change
            if current_mute_status ~= stored_mute_status then
                return true
            end
            
            -- Count items only for unmuted tracks
            if not current_mute_status then
            text_items_count = text_items_count + reaper.CountTrackMediaItems(track_id)
            end
        end
    end
    
    if CountTracks ~= last_CountTracks then
        last_CountTracks = CountTracks
        return true
    elseif text_items_count ~= last_text_items_count then
        last_text_items_count = text_items_count
        return true
    end
    
    -- Check for BPM change
    local current_BPM = reaper.Master_GetTempo()
    if current_BPM ~= last_BPM then
        last_BPM = current_BPM
        return true
    end
    
    -- Any remaining project-state change can be an item move, trim or manual
    -- boundary edit. Those changes alter both displayed time and active phrase.
    return true
end


-- 🪟 UI utility functions
local function tooltip(text)
    if not show_tooltips then return end
    if reaper.ImGui_IsItemHovered(ctx) then
        local now = reaper.time_precise()
        local st = tooltip_state[text]
        if not st then
            tooltip_state[text] = { start = now }
        else
            if now - st.start >= tooltip_delay then
                -- use short form for stability
                reaper.ImGui_SetTooltip(ctx, text)
            end
        end
    else
        tooltip_state[text] = nil
    end
end

local function smooth_scroll(target_scroll)
    local scroll_y = reaper.ImGui_GetScrollY(ctx)
    local scroll_max = reaper.ImGui_GetScrollMaxY(ctx)
    target_scroll = math.max(0, math.min(target_scroll, scroll_max))

    if math.abs(scroll_y - target_scroll) > 0.5 then
        -- Calculate adaptive speed based on distance
        local distance = math.abs(target_scroll - scroll_y)
        local half_h = ui_dimensions.win_height * 0.5
        local adaptive_speed = scroll_speed
        
        -- Increase speed proportionally based on distance
        if ui_dimensions.win_height > 0 then
            if distance > half_h then
                adaptive_speed = scroll_speed * distance / half_h
            end
        end
        if adaptive_speed > 0.9 then
            adaptive_speed = 0.9
        end
        local new_scroll = scroll_y + (target_scroll - scroll_y) * adaptive_speed
        reaper.ImGui_SetScrollY(ctx, new_scroll)
        return true
    else
        reaper.ImGui_SetScrollY(ctx, target_scroll)
        return false
    end
end

local function scroll_to_center()
    if central_y and ui_dimensions.win_height > 0 then
        local target_scroll = central_y - (ui_dimensions.win_height * 0.5)
        local scroll_max = reaper.ImGui_GetScrollMaxY(ctx)
        target_scroll = math.max(0, math.min(target_scroll, scroll_max))
        
        -- Check for manual scroll (mouse wheel or drag scrollbar)
        local wheel_delta = window_hovered and reaper.ImGui_GetMouseWheel and reaper.ImGui_GetMouseWheel(ctx) or 0
        local mouse_drag = window_hovered and (reaper.ImGui_IsMouseDragging(ctx, 0) or reaper.ImGui_IsMouseDragging(ctx, 1))
        local manual_scroll = (wheel_delta ~= 0) or mouse_drag
        
        -- Check auto-scroll delay
        local allow_auto_scroll = (cur_time - hovered_time > scroll_delay)
        
        -- Check if the central element position has changed
        local central_changed = (central_y ~= last_central_y)
        
        -- If manual scroll, immediately interrupt auto-scroll
        if manual_scroll then
            target_scroll_y = nil
        end
        
        if smooth_scroll_enabled then
            -- SMOOTH SCROLL
            if target_scroll_y then
                -- Scroll is already in progress
                if manual_scroll then
                    -- Interrupt on manual scroll
                    target_scroll_y = nil
                elseif central_changed and allow_auto_scroll then
                    -- If the position has changed and the delay has passed, start a new scroll
                    target_scroll_y = target_scroll
                else
                    -- Continue the current scroll
                    if not smooth_scroll(target_scroll_y) then
                        target_scroll_y = nil  -- scroll completed 
                    end
                end
            else
                -- No scroll - start a new one only if the window is not hovered and the delay has passed 
                if not window_hovered and allow_auto_scroll then
                    target_scroll_y = target_scroll
                end
            end
        else
            -- INSTANT SCROLL - only if the window is not hovered and the delay has passed
            if not window_hovered and allow_auto_scroll then
                reaper.ImGui_SetScrollY(ctx, target_scroll)
            end
        end
        
        -- Remember the current position for the next check
        last_central_y = central_y
    end

end

local function draw_search_highlight(text, search_query, text_col_w)
    -- Function to draw text with highlighted search terms
    -- Works with word wrapping and respects ignore_newlines
    -- IMPORTANT: called AFTER setting the font and cursor position!
    
    local query_lower = utf8lower(search_query or "")
    local norm = tostring(text or ""):gsub("\r\n","\n"):gsub("\r","\n")
    
    -- === BUILT-IN LOGIC FOR CONSTRUCTING VISUAL LINES ===
    local vlines = {}
    
    if auto_wrap_enabled and (text_col_w or 0) > 0 then
        -- Paragraph wrapping function
        local function wrap_paragraph(paragraph)
            local lines = {}
            local cur = ""
            local cur_w = 0
            
            for word, space in paragraph:gmatch("(%S+)(%s*)") do
                local segment = word .. space
                local seg_w = reaper.ImGui_CalcTextSize(ctx, segment)
                
                if seg_w > text_col_w and cur == "" then
                    -- Word wider than line - cut by characters
                    for uchar in segment:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                        local ww = reaper.ImGui_CalcTextSize(ctx, uchar)
                        if cur_w + ww > text_col_w and cur ~= "" then
                            lines[#lines+1] = cur
                            cur, cur_w = "", 0
                        end
                        cur = cur .. uchar
                        cur_w = cur_w + ww
                    end
                elseif cur_w + seg_w > text_col_w and cur ~= "" then
                    -- Wrap to new line
                    lines[#lines+1] = cur
                    cur, cur_w = segment, seg_w
                else
                    cur = cur .. segment
                    cur_w = cur_w + seg_w
                end
            end
            lines[#lines+1] = cur
            return lines
        end
        
        -- Processing text with respect to ignore_newlines
        if ignore_newlines then
            -- Everything in one paragraph
            local chunk = norm:gsub("\n", " ")
            local wrapped = wrap_paragraph(chunk)
            for _, ln in ipairs(wrapped) do vlines[#vlines+1] = ln end
        else
            -- By paragraphs
            for para in (norm .. "\n"):gmatch("([^\n]*)\n") do
                local wrapped = wrap_paragraph(para)
                for _, ln in ipairs(wrapped) do vlines[#vlines+1] = ln end
            end
            if #vlines == 0 then vlines[1] = "" end
        end
    else
        -- Without word wrapping - just split by lines respecting ignore_newlines
        if ignore_newlines then
            vlines[1] = norm:gsub("\n"," ")
        else
            for ln in (norm .. "\n"):gmatch("([^\n]*)\n") do
                vlines[#vlines+1] = ln
            end
            if #vlines == 0 then vlines[1] = "" end
        end
    end
    
    -- === DRAWING WITH HIGHLIGHT ===
    local start_x, start_y = reaper.ImGui_GetCursorPos(ctx)
    local line_h = reaper.ImGui_GetTextLineHeight(ctx)
    
    for li, line in ipairs(vlines) do
        local y_pos = start_y + (li - 1) * line_h
        reaper.ImGui_SetCursorPos(ctx, start_x, y_pos)
        
        -- Search for matches in the line
        local name_lower = utf8lower(line)
        local s_pos, e_pos = nil, nil
        if query_lower ~= "" then
            s_pos, e_pos = name_lower:find(query_lower, 1, true)
        end
        
        if s_pos then
            -- Found - split into 3 parts
            local before = line:sub(1, s_pos - 1)
            local match = line:sub(s_pos, e_pos)
            local after = line:sub(e_pos + 1)
            
            -- Draw with highlight
            reaper.ImGui_Text(ctx, before)
            reaper.ImGui_SameLine(ctx, 0, 0)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color_settings.search_highlight)
            reaper.ImGui_Text(ctx, match)
            reaper.ImGui_PopStyleColor(ctx)
            reaper.ImGui_SameLine(ctx, 0, 0)
            reaper.ImGui_Text(ctx, after)
        else
            -- No match
            reaper.ImGui_Text(ctx, line)
        end
    end
    
    -- Set cursor after the last line
    reaper.ImGui_SetCursorPos(ctx, start_x, start_y + #vlines * line_h)
end


-- 🎨 Drawing elements
local item_palette = {}
local custom_picker_color = 0x7F7F7FFF
local custom_picker_undo_open = false

local function load_item_palette()
    local loaded = {}
    local ini_path = reaper.get_ini_file()
    local file = ini_path and io.open(ini_path, "r") or nil
    if file then
        local in_palette = false
        for line in file:lines() do
            line = line:gsub("^%s*(.-)%s*$", "%1")
            if line:lower() == "[colorpal]" then
                in_palette = true
            elseif line:sub(1, 1) == "[" then
                in_palette = false
            elseif in_palette then
                local key, value = line:match("([^=]+)=([^=]+)")
                local index = key and tonumber(key:gsub("%s+", ""):match("color(%d+)"))
                local native = value and tonumber(value:gsub("%s+", ""))
                if index and index >= 1 and index <= 16 and native and native ~= 0 then
                    local red, green, blue = reaper.ColorFromNative(native)
                    loaded[index] = { r = red, g = green, b = blue }
                end
            end
        end
        file:close()
    end
    for index = 1, 16 do
        if loaded[index] then item_palette[#item_palette+1] = loaded[index] end
    end
    if #item_palette < 6 then
        item_palette = {
            {r=96,g=184,b=150}, {r=84,g=151,b=180},
            {r=111,g=153,b=132}, {r=103,g=116,b=164},
            {r=114,g=123,b=143}, {r=92,g=160,b=140},
            {r=150,g=107,b=151}, {r=181,g=91,b=127},
            {r=143,g=146,b=105}, {r=164,g=98,b=142},
            {r=218,g=91,b=99}, {r=231,g=132,b=78},
        }
    end
end

load_item_palette()

local function rgba(red, green, blue, alpha)
    return (red << 24) | (green << 16) | (blue << 8) | (alpha or 0xFF)
end

local function item_color_to_rgba(native_color)
    if not native_color or native_color == 0 then return nil end
    local red, green, blue = reaper.ColorFromNative(native_color)
    return rgba(red, green, blue)
end

local function selected_item_color()
    local count = reaper.CountSelectedMediaItems(0)
    if count == 0 then return nil end
    local color = reaper.GetMediaItemInfo_Value(
        reaper.GetSelectedMediaItem(0, 0), "I_CUSTOMCOLOR")
    for index = 1, count - 1 do
        if reaper.GetMediaItemInfo_Value(
            reaper.GetSelectedMediaItem(0, index), "I_CUSTOMCOLOR") ~= color then
            return nil
        end
    end
    return color
end

local function apply_selected_item_color(native_color, manage_undo)
    local count = reaper.CountSelectedMediaItems(0)
    if count == 0 then return end
    if manage_undo ~= false then reaper.Undo_BeginBlock() end
    for index = 0, count - 1 do
        reaper.SetMediaItemInfo_Value(
            reaper.GetSelectedMediaItem(0, index), "I_CUSTOMCOLOR", native_color)
    end
    reaper.UpdateArrange()
    invalidate_combined_cache()
    update()
    if manage_undo ~= false then
        reaper.Undo_EndBlock("ReaTitles: Color phrase group", -1)
    end
end

local function draw_palette_circle(id, draw_color, selected, draw_custom)
    local size, radius = 18, 6.25
    local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_InvisibleButton(ctx, id, size, size)
    local hovered = reaper.ImGui_IsItemHovered(ctx)
    local clicked = reaper.ImGui_IsItemClicked(ctx, 0)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local cx, cy = x + size * 0.5, y + size * 0.5
    local actual_radius = hovered and radius + 0.5 or radius
    if draw_custom then
        local wheel = {
            0xFF5A67FF, 0xFFB34FFF, 0xF4E35CFF,
            0x61D68AFF, 0x55B9F3FF, 0xA978F4FF,
        }
        for index, color in ipairs(wheel) do
            local a1 = (index - 1) * math.pi / 3 - math.pi / 2
            local a2 = index * math.pi / 3 - math.pi / 2
            reaper.ImGui_DrawList_AddTriangleFilled(
                dl, cx, cy,
                cx + math.cos(a1) * actual_radius,
                cy + math.sin(a1) * actual_radius,
                cx + math.cos(a2) * actual_radius,
                cy + math.sin(a2) * actual_radius,
                color)
        end
    else
        reaper.ImGui_DrawList_AddCircleFilled(
            dl, cx, cy, actual_radius, draw_color, 0)
    end
    if selected then
        reaper.ImGui_DrawList_AddCircle(
            dl, cx, cy, actual_radius + 1.5, 0xFFFFFFFF, 0, 1.5)
        reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, 1.8, 0xFFFFFFFF, 0)
    elseif hovered then
        reaper.ImGui_DrawList_AddCircle(
            dl, cx, cy, actual_radius + 1, 0xFFFFFF99, 0, 1)
    end
    return clicked
end

local function draw_item_palette()
    local current = selected_item_color()
    local theme_native = reaper.GetThemeColor("col_mi_bg", 0)
    local tr, tg, tb = reaper.ColorFromNative(theme_native)
    local start_x, start_y = reaper.ImGui_GetCursorPos(ctx)
    local available_width = reaper.ImGui_GetContentRegionAvail(ctx)
    local side_padding = 8
    local cell_size = 18
    local column_gap = 4
    local row_gap = 4
    local usable_width = math.max(cell_size, available_width - side_padding * 2)
    local total_cells = #item_palette + 2
    local max_columns = math.max(
        1, math.floor((usable_width + column_gap) / (cell_size + column_gap)))
    local row_count = math.ceil(total_cells / max_columns)

    local function place_cell(ordinal)
        local row = math.floor((ordinal - 1) / max_columns)
        local column = (ordinal - 1) % max_columns
        local cells_in_row = math.min(max_columns, total_cells - row * max_columns)
        local row_width =
            cells_in_row * cell_size + math.max(0, cells_in_row - 1) * column_gap
        local row_start_x =
            start_x + side_padding + math.max(0, (usable_width - row_width) * 0.5)
        reaper.ImGui_SetCursorPos(
            ctx,
            row_start_x + column * (cell_size + column_gap),
            start_y + row * (cell_size + row_gap))
    end

    local ordinal = 1
    place_cell(ordinal)
    if draw_palette_circle(
        "##item_color_default", rgba(tr, tg, tb), current == 0, false) then
        apply_selected_item_color(0)
    end
    for index, color in ipairs(item_palette) do
        ordinal = ordinal + 1
        place_cell(ordinal)
        local native = reaper.ColorToNative(color.r, color.g, color.b) | 0x1000000
        if draw_palette_circle(
            "##item_color_" .. index, rgba(color.r, color.g, color.b),
            current == native, false) then
            apply_selected_item_color(native)
        end
    end
    ordinal = ordinal + 1
    place_cell(ordinal)
    if draw_palette_circle("##item_color_custom", 0, false, true) then
        local initial = current and current ~= 0 and current or theme_native
        local red, green, blue = reaper.ColorFromNative(initial)
        custom_picker_color = rgba(red, green, blue)
        if not custom_picker_undo_open then
            reaper.Undo_BeginBlock()
            custom_picker_undo_open = true
        end
        reaper.ImGui_OpenPopup(ctx, "##item_custom_color_popup")
    end
    local picker_visible = reaper.ImGui_BeginPopup(ctx, "##item_custom_color_popup")
    if picker_visible then
        local changed, chosen = reaper.ImGui_ColorPicker3(
            ctx, "##item_custom_color_picker", custom_picker_color, 0)
        if changed then
            custom_picker_color = chosen
            local red = (chosen >> 24) & 0xFF
            local green = (chosen >> 16) & 0xFF
            local blue = (chosen >> 8) & 0xFF
            apply_selected_item_color(
                reaper.ColorToNative(red, green, blue) | 0x1000000, false)
        end
        reaper.ImGui_EndPopup(ctx)
    elseif custom_picker_undo_open then
        reaper.Undo_EndBlock("ReaTitles: Custom phrase color", -1)
        custom_picker_undo_open = false
    end
    local palette_height =
        row_count * cell_size + math.max(0, row_count - 1) * row_gap
    reaper.ImGui_SetCursorPos(ctx, start_x, start_y + palette_height)
end

local function topmenu()
    if reaper.ImGui_Button(ctx, str.i_import) then
        local info = debug.getinfo(1, "S")
        local base = (info.source:match("@?(.*[\\/])") or "")
        local importer = base .. "ch_import_text_items_from_sub.lua"
        if reaper.file_exists(importer) then
            local ok, err = pcall(dofile, importer)
            if not ok then reaper.ShowMessageBox(tostring(err), TITLE .. " - Import", 0) end
            invalidate_combined_cache()
            update()
        else
            reaper.ShowMessageBox("Subtitle importer not found:\n" .. importer, TITLE, 0)
        end
    end

    reaper.ImGui_SameLine(ctx, 0, 10)
    if reaper.ImGui_Button(ctx, "Word") then
        local info = debug.getinfo(1, "S")
        local base = (info.source:match("@?(.*[\\/])") or "")
        local module = base .. "rt_word_roundtrip.lua"
        local ok, err = pcall(dofile, module)
        if not ok then
            reaper.ShowMessageBox(tostring(err), TITLE .. " - Word", 0)
        end
        invalidate_combined_cache()
        update()
    end

    reaper.ImGui_SameLine(ctx, 0, 10)
    reaper.ImGui_PushItemWidth(ctx, 100)
    local preview = (combo_sources[source_idx] and combo_sources[source_idx].name) or str.i_sources
    if reaper.ImGui_BeginCombo(ctx, "##source_combo", preview) then
        for i, src in ipairs(combo_sources) do
            local selected = (i == source_idx)
            local label = (src.name or ("источник " .. i)) .. "##" .. tostring(src.track_guid or i)
            if reaper.ImGui_Selectable(ctx, label, selected) then
                source_idx = i
                source_guid = src.guid
                calculate_time_width()
                save_settings()  -- save settings when changing source
            end
        end
        reaper.ImGui_EndCombo(ctx)
    end
    reaper.ImGui_PopItemWidth(ctx)

    -- language selection
    reaper.ImGui_SameLine(ctx, 0, 10)
    if reaper.ImGui_Button(ctx, lang) then
        reaper.ImGui_OpenPopup(ctx, "lang_popup")
    end
    if reaper.ImGui_BeginPopup(ctx, "lang_popup") then
        for _, code in ipairs(languages) do
            if reaper.ImGui_Selectable(ctx, code, code == lang) then
                lang = code
                load_language_strings(lang)
                get_combo_list()  -- recreate combo list with new strings
            end
        end
        reaper.SetExtState(SETTINGS, "lang", lang, true)
        reaper.ImGui_EndPopup(ctx)
    end

    -- search field
    reaper.ImGui_Text(ctx, "🔎")
    reaper.ImGui_SameLine(ctx, 0, 5)
    reaper.ImGui_PushItemWidth(ctx, 214)
    local changed, new_search = reaper.ImGui_InputText(ctx, "##search", search, 0)
    if changed then
        search = new_search
    end
    reaper.ImGui_PopItemWidth(ctx)


    reaper.ImGui_SameLine(ctx, 0, 0)
    if reaper.ImGui_Button(ctx, "⌫") then
        search = ""
    end

    -- Refresh on the second row, aligned to the right edge.
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetCursorPosX(
        ctx, math.max(reaper.ImGui_GetCursorPosX(ctx),
                      reaper.ImGui_GetWindowWidth(ctx) - 32))
    if reaper.ImGui_Button(ctx, "⟳", 24, 0) then
        update()
    end

    reaper.ImGui_Dummy(ctx, 0, 4)

    -- Separator line
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local wx, wy = reaper.ImGui_GetWindowPos(ctx)
    local ww = reaper.ImGui_GetWindowWidth(ctx)
    reaper.ImGui_DrawList_AddLine(dl, wx + 8, wy + reaper.ImGui_GetCursorPosY(ctx),
                                  wx + ww - 8, wy + reaper.ImGui_GetCursorPosY(ctx),
                                  0x222235FF, 1.0)
    reaper.ImGui_Dummy(ctx, 0, 4)

    draw_item_palette()
    reaper.ImGui_Dummy(ctx, 0, 2)
end

local function context_menu()
    if reaper.ImGui_BeginPopup(ctx, "ctx_menu") then 
        reaper.ImGui_PushItemWidth(ctx, 140)
        
        local ch = 0
        local function add_change(changed, new_value)
            if changed then ch = ch + 1 end
            return new_value
        end
        
        reaper.ImGui_Text(ctx, str.c_regions)
        -- Font for regions
        if reaper.ImGui_BeginCombo(ctx, "##region_font", font_names[font_settings.region.idx]) then
            for i, name in ipairs(font_names) do
                if reaper.ImGui_Selectable(ctx, name, i == font_settings.region.idx) then
                    font_settings.region.idx = add_change(i, i)
                    font_settings.region.font = fonts[font_settings.region.idx]
                end
            end
            reaper.ImGui_EndCombo(ctx)
        end
        tooltip(str.t_region_font)
        -- Scale for regions
        font_settings.region.scale = add_change(reaper.ImGui_SliderInt(ctx, "##region_scale", font_settings.region.scale, 10, 100))
        tooltip(str.t_region_scale)
        
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Text(ctx, str.c_items)
        -- Font for items
        if reaper.ImGui_BeginCombo(ctx, "##item_font", font_names[font_settings.item.idx]) then
            for i, name in ipairs(font_names) do
                if reaper.ImGui_Selectable(ctx, name, i == font_settings.item.idx) then
                    font_settings.item.idx = add_change(i, i)
                    font_settings.item.font = fonts[font_settings.item.idx]
                end
            end
            reaper.ImGui_EndCombo(ctx)
        end
        tooltip(str.t_item_font)
        -- Scale for items
        font_settings.item.scale = add_change(reaper.ImGui_SliderInt(ctx, "##item_scale", font_settings.item.scale, 10, 100))
        tooltip(str.t_item_scale)

        -- Central scale
        reaper.ImGui_Separator(ctx)
        central_scale_enabled = add_change(reaper.ImGui_Checkbox(ctx, str.c_central_scale, central_scale_enabled or false))
        tooltip(str.t_central_scale_title)
        if central_scale_enabled then
            central_scale = add_change(reaper.ImGui_SliderDouble(ctx, "##central_scale", central_scale, 1.0, 1.5, "%.2f"))
            tooltip(str.t_central_scale)
        end

        -- Colors
        reaper.ImGui_Separator(ctx)
        local function color_edit(label, val)
            local changed
            changed, val = reaper.ImGui_ColorEdit4(
                ctx, label, val,
                reaper.ImGui_ColorEditFlags_NoInputs() | reaper.ImGui_ColorEditFlags_AlphaBar()
            )
            return add_change(changed, val)
        end
        
        color_settings.region.normal     = color_edit(str.c_region_color, color_settings.region.normal)
        color_settings.region.highlight = color_edit(str.c_region_highlight, color_settings.region.highlight)
        color_settings.item.normal       = color_edit(str.c_item_color, color_settings.item.normal)
        color_settings.item.highlight   = color_edit(str.c_item_highlight, color_settings.item.highlight)
        color_settings.search_highlight = color_edit(str.c_search_highlight, color_settings.search_highlight)

        -- Functions
        reaper.ImGui_Separator(ctx)
        smooth_scroll_enabled = add_change(reaper.ImGui_Checkbox(ctx, str.c_smooth_scroll, smooth_scroll_enabled))
        tooltip(str.t_smooth_scroll)
        auto_wrap_enabled = add_change(reaper.ImGui_Checkbox(ctx, str.c_auto_wrap, auto_wrap_enabled))
        tooltip(str.t_auto_wrap)
        
        local old_ignore_newlines = ignore_newlines
        ignore_newlines = add_change(reaper.ImGui_Checkbox(ctx, str.c_ignore_newlines, ignore_newlines))
        tooltip(str.t_ignore_newlines)
        if old_ignore_newlines ~= ignore_newlines then
            invalidate_combined_cache()
            update() -- rescan data on option change
        end

        auto_update_enabled = add_change(reaper.ImGui_Checkbox(ctx, str.c_auto_update, auto_update_enabled))
        tooltip(str.t_auto_update)

        -- Autostart on REAPER start
        local old_autostart = autostart_on_reaper
        autostart_on_reaper = add_change(reaper.ImGui_Checkbox(ctx, str.c_autostart_reaper, autostart_on_reaper))
        tooltip(str.t_autostart_reaper)
        if old_autostart ~= autostart_on_reaper then
            manage_startup_autostart(autostart_on_reaper)
            ch = ch + 1
        end
        
        -- Tooltips + delay
        reaper.ImGui_Separator(ctx)
        show_tooltips = add_change(reaper.ImGui_Checkbox(ctx, str.c_show_tooltips, show_tooltips))
        tooltip(str.t_show_tooltips)
        
        -- Save settings only if there were changes
        if ch > 0 then
            calculate_time_width()
            save_settings()
        end

        reaper.ImGui_PopItemWidth(ctx)
        reaper.ImGui_EndPopup(ctx)
    else
        want_context_menu = false
    end
end

local function draw_list()
    -- set number of central elements
    local central_count = 0
    central_y = nil

    -- Window coordinates for drawing
    local wx, wy = reaper.ImGui_GetWindowPos(ctx)
    local row_bounds = {}

    local display_data = (search and search ~= "") and search_filter(src.data, search) or src.data

    local pos = ((ps & 1) == 1) and playhead or cursor
    local idx_list
    
    if search and search ~= "" then
        -- For search, find index in filtered data
        idx_list = get_current_index(pos, {data = display_data, kind = src.kind, guid = src.guid})
    else
        -- Without search, find index in original data
        idx_list = get_current_index(pos, src)
    end
    
    -- Create set for quick check
    local idx_set = {}
    if idx_list then
        for _, idx in ipairs(idx_list) do
            idx_set[idx] = true
        end
    end

    -- If list is empty - draw nothing
    if #display_data == 0 then
        return
    end

    -- Validate editing index
    if editing_idx and (editing_idx < 1 or editing_idx > #display_data) then
        editing_idx = nil
        edit_buf = ""
        edit_focus_pending = false
        edit_had_focus = false
    end

    -- Validate drag index
    if drag_source_idx and (drag_source_idx < 1 or drag_source_idx > #display_data) then
        drag_source_idx = nil
        drag_drop_idx = nil
        drag_offset_y = nil
        drag_start_y = nil
    end

    -- Define base styles based on source type
    local base_font, base_scale, base_color, base_highlight
    if src.kind == "regions" then
        base_font, base_scale, base_color, base_highlight = font_settings.region.font, font_settings.region.scale, color_settings.region.normal, color_settings.region.highlight
    else
        base_font, base_scale, base_color, base_highlight = font_settings.item.font, font_settings.item.scale, color_settings.item.normal, color_settings.item.highlight
    end

    -- draw list
    for i, r in ipairs(display_data) do
        local time, line = r.start_str, (r.name or "")
        
        -- Check if element is central
        local is_current = idx_set[i]
        
        -- Define styles for specific element (for combined source)
        local element_font, element_scale, element_color, element_highlight = base_font, base_scale, base_color, base_highlight
        if src.kind == "combined" then
            if r.type == "region" then
                element_font = font_settings.region.font
                element_scale = font_settings.region.scale
                element_color = color_settings.region.normal
                element_highlight = color_settings.region.highlight
            elseif r.type == "text_item" then
                element_font = font_settings.item.font
                element_scale = font_settings.item.scale
                element_color = color_settings.item.normal
                element_highlight = color_settings.item.highlight
            end
        end
        if r.type == "text_item" then
            element_color = item_color_to_rgba(r.custom_color) or element_color
        end
        
        -- Calculate central_scale AFTER defining element_scale for specific type
        local element_central_scale
        if central_scale_enabled then
            element_central_scale = element_scale*central_scale
        else
            element_central_scale = element_scale
        end
        
        -- read cursor start
        local x1, y1 = reaper.ImGui_GetCursorPos(ctx)
        
        -- Apply styles
        if is_current then
            central_count = central_count + 1
            reaper.ImGui_PushFont(ctx, element_font, element_central_scale)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), element_highlight)
        else
            reaper.ImGui_PushFont(ctx, element_font, element_scale)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), element_color)
        end

        -- enable auto-wrap
        if auto_wrap_enabled then
            reaper.ImGui_PushTextWrapPos(ctx, ui_dimensions.win_width-10)
        end
    

        -- draw text
        reaper.ImGui_Text(ctx, time)
        reaper.ImGui_SameLine(ctx)
        if is_current and central_count == 1 then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.accent)
            reaper.ImGui_Text(ctx, " ")
            reaper.ImGui_PopStyleColor(ctx)
            reaper.ImGui_SameLine(ctx)
        end
        
        -- Set position for subtitle text
        reaper.ImGui_SetCursorPosX(ctx, ui_dimensions.time_width + ui_dimensions.space_width)

        -- Inline editing: show InputText when this item is being edited
        if editing_idx == i then
            local text_w = ui_dimensions.win_width - 10 - ui_dimensions.time_width - ui_dimensions.space_width
            reaper.ImGui_PushItemWidth(ctx, text_w)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x1A2A3AFF)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(), 0x1A2A3AFF)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0x1A2A3AFF)
            if edit_focus_pending then
                reaper.ImGui_SetKeyboardFocusHere(ctx)
                edit_focus_pending = false
            end
            local submitted, new_text = reaper.ImGui_InputText(
                ctx, "##edit_"..i, edit_buf,
                reaper.ImGui_InputTextFlags_EnterReturnsTrue())
            if type(new_text) == "string" then edit_buf = new_text end
            reaper.ImGui_PopStyleColor(ctx, 3)

            local editor_active = reaper.ImGui_IsItemActive(ctx)
            local editor_focused = reaper.ImGui_IsItemFocused(ctx)
            if editor_active or editor_focused then edit_had_focus = true end
            local focus_lost = edit_had_focus and
                not editor_active and not editor_focused and
                reaper.ImGui_IsMouseClicked(ctx, 0)

            if submitted or focus_lost then
                local item_to_save = display_data[editing_idx]
                if item_to_save and edit_buf ~= (item_to_save.name or "") then
                    reaper.Undo_BeginBlock()
                    local saved = save_element_text(item_to_save, edit_buf)
                    reaper.Undo_EndBlock("ReaTitles: Edit subtitle text", -1)
                    if saved then
                        reaper.UpdateArrange()
                    end
                    invalidate_combined_cache()
                    update()
                end
                editing_idx = nil
                edit_buf = ""
                edit_had_focus = false
            end

            -- Cancel on Escape
            if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
                editing_idx = nil
                edit_buf = ""
                edit_focus_pending = false
                edit_had_focus = false
            end

            reaper.ImGui_PopItemWidth(ctx)
        else
            -- Normal display
            if search and search ~= "" then
                local text_col_w = ui_dimensions.win_width - 10 - ui_dimensions.time_width - ui_dimensions.space_width
                draw_search_highlight(line, search, text_col_w)
            else
                reaper.ImGui_Text(ctx, line)
            end
        end

        if auto_wrap_enabled then
            reaper.ImGui_PopTextWrapPos(ctx)
        end

        -- disable style
        reaper.ImGui_PopStyleColor(ctx)
        reaper.ImGui_PopFont(ctx)
        

        -- read cursor end
        local x2, y2 = reaper.ImGui_GetCursorPos(ctx)
        
        -- Draw subtle separator line
        if i < #display_data then
            local dl = reaper.ImGui_GetWindowDrawList(ctx)
            reaper.ImGui_DrawList_AddLine(dl,
                wx + 12, wy + y2 + 1,
                wx + ui_dimensions.win_width - 12, wy + y2 + 1,
                0x1A1A2E40)
        end
        
        -- Remember position of first central element
        if central_count == 1 and not central_y then
            central_y = y1 + (y2 - y1) * 0.5
        end
        
        -- The row hit target must not cover the active text editor.
        if editing_idx ~= i then
        -- draw button with drag & drop
        reaper.ImGui_SetCursorPos(ctx, x1, y1)
        reaper.ImGui_InvisibleButton(ctx, "##row_"..i, -1, y2 - y1)
        local row_hovered = reaper.ImGui_IsItemHovered(ctx)
        local rect_x1, rect_y1 = reaper.ImGui_GetItemRectMin(ctx)
        local rect_x2, rect_y2 = reaper.ImGui_GetItemRectMax(ctx)
        row_bounds[i] = {
            left = rect_x1, top = rect_y1, right = rect_x2, bottom = rect_y2
        }

        -- Ctrl+Click: delete item
        if row_hovered and reaper.ImGui_IsItemClicked(ctx, 0) and reaper.ImGui_GetKeyMods(ctx) == reaper.ImGui_Mod_Ctrl() then
            reaper.Undo_BeginBlock()
            local deleted = delete_display_element(r)
            reaper.UpdateArrange()
            reaper.Undo_EndBlock("ReaTitles: Delete item", -1)
            if deleted then
                invalidate_combined_cache()
                update()
                return
            end
        -- Double-click: edit text
        elseif row_hovered and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
            editing_idx = i
            edit_buf = r.name or ""
            edit_focus_pending = true
            edit_had_focus = false

        -- Mouse down: prepare for drag OR click
        elseif row_hovered and reaper.ImGui_IsMouseClicked(ctx, 0) then
            drag_source_idx = i
            local _, mouse_y = reaper.ImGui_GetMousePos(ctx)
            drag_start_y = mouse_y
            drag_offset_y = nil
            drag_drop_idx = nil
        end

        -- Detect drag threshold while holding
        if drag_source_idx and drag_source_idx == i and drag_start_y and not drag_offset_y then
            local _, mouse_y = reaper.ImGui_GetMousePos(ctx)
            if math.abs(mouse_y - drag_start_y) > 8 then
                drag_offset_y = mouse_y - rect_y1
            end
        end

        -- Only show drag visuals if drag is active
        if drag_source_idx and drag_offset_y then
            -- Draw ghost on the dragged row
            if drag_source_idx == i then
                local dl = reaper.ImGui_GetWindowDrawList(ctx)
                local _, mouse_y = reaper.ImGui_GetMousePos(ctx)
                local ghost_y = mouse_y - drag_offset_y
                local row_h = y2 - y1

                reaper.ImGui_DrawList_AddRectFilled(dl,
                    wx + 2, ghost_y,
                    wx + ui_dimensions.win_width - 2, ghost_y + row_h,
                    0x252540DD, 6)
                reaper.ImGui_DrawList_AddRect(dl,
                    wx + 2, ghost_y,
                    wx + ui_dimensions.win_width - 2, ghost_y + row_h,
                    0x00E5B4AA, 6, nil, 1.5)
                reaper.ImGui_DrawList_AddText(dl,
                    wx + ui_dimensions.time_width + 12, ghost_y + 4,
                    0xCCCCCCFF, r.name or "")
            end
        end
        else
            row_bounds[i] = {
                left = wx + x1, top = wy + y1,
                right = wx + ui_dimensions.win_width - 2, bottom = wy + y2
            }
        end

    end

    -- Resolve the destination continuously from screen-space row geometry.
    -- This remains reliable while the ghost crosses text, gaps or wrapped rows.
    if drag_source_idx and drag_offset_y then
        local _, mouse_y = reaper.ImGui_GetMousePos(ctx)
        local nearest_idx, nearest_distance = nil, math.huge
        for i, bounds in ipairs(row_bounds) do
            local center = (bounds.top + bounds.bottom) * 0.5
            local distance = math.abs(mouse_y - center)
            if distance < nearest_distance then
                nearest_idx, nearest_distance = i, distance
            end
        end
        drag_drop_idx = nearest_idx

        local dl = reaper.ImGui_GetWindowDrawList(ctx)
        local source_bounds = row_bounds[drag_source_idx]
        if source_bounds then
            reaper.ImGui_DrawList_AddRectFilled(
                dl, source_bounds.left, source_bounds.top,
                source_bounds.right, source_bounds.bottom, 0xFF8A0028, 4)
            reaper.ImGui_DrawList_AddRect(
                dl, source_bounds.left, source_bounds.top,
                source_bounds.right, source_bounds.bottom, 0xFFB000FF, 4, nil, 2)
        end

        if drag_drop_idx and drag_drop_idx ~= drag_source_idx then
            local target = row_bounds[drag_drop_idx]
            if target then
                local indicator_y = (drag_drop_idx > drag_source_idx)
                    and target.bottom or target.top
                reaper.ImGui_DrawList_AddRectFilled(
                    dl, target.left, indicator_y - 3,
                    target.right, indicator_y + 3, 0x00E5B4FF, 2)
            end
        end
    end

    -- Handle mouse release AFTER the loop
    if drag_source_idx and reaper.ImGui_IsMouseReleased(ctx, 0) then
        -- Click: select item + jump to position
        local item = display_data[drag_source_idx]
        if item then
            if item.item_ptr then select_item_pair(item.item_ptr) end
            reaper.SetEditCurPos(item.start_time or 0, true, true)
            reaper.ImGui_SetClipboardText(ctx, string.format("%s - %s", item.start_str or "", item.name or ""))
        end
        drag_source_idx = nil
        drag_drop_idx = nil
        drag_offset_y = nil
        drag_start_y = nil
    end

    -- Cancel drag on Escape
    if drag_source_idx and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
        drag_source_idx = nil
        drag_drop_idx = nil
        drag_offset_y = nil
        drag_start_y = nil
    end

end

local function debug_window()
    reaper.ImGui_SetNextWindowSize(ctx, 300, 200, reaper.ImGui_Cond_Always())
    local visible, open = reaper.ImGui_Begin(ctx, "Debug Info", true)
    if visible then
        reaper.ImGui_Text(ctx, "Project: " .. tostring(proj_name) .. " [" .. tostring(proj_guid) .. "]")
        reaper.ImGui_Text(ctx, "Tracks: " .. tostring(reaper.CountTracks(0)) .. ", Regions: " .. tostring(reaper.CountProjectMarkers(0)))
        reaper.ImGui_Text(ctx, "Source: " .. tostring((combo_sources[source_idx] and combo_sources[source_idx].name) or "nil"))
        reaper.ImGui_Text(ctx, "Cursor: " .. string.format("%.3f", cursor) .. ", Playhead: " .. string.format("%.3f", playhead) .. ", State: " .. tostring(ps))
        reaper.ImGui_Text(ctx, "Items by track: " .. tostring(#cur_items_by_track) .. ", Regions: " .. tostring(#cur_regions))
        reaper.ImGui_Text(ctx, "Combined cache valid: " .. tostring(combined_cache_valid))
    end
    reaper.ImGui_End(ctx)
end

-- 🚦 Main loop
local function forward_reaper_shortcuts()
    if reaper.ImGui_IsAnyItemActive and
       reaper.ImGui_IsAnyItemActive(ctx) then
        return
    end

    local mods = reaper.ImGui_GetKeyMods(ctx)
    local ctrl_flag = reaper.ImGui_Mod_Ctrl()
    local shift_flag = reaper.ImGui_Mod_Shift()
    local ctrl = (mods & ctrl_flag) ~= 0
    local shift = (mods & shift_flag) ~= 0
    local function pressed(key_function)
        return key_function and
            reaper.ImGui_IsKeyPressed(ctx, key_function(), false)
    end

    if pressed(reaper.ImGui_Key_Space) then
        reaper.Main_OnCommandEx(40044, 0, 0)
    elseif ctrl and shift and pressed(reaper.ImGui_Key_Z) then
        reaper.Main_OnCommandEx(40030, 0, 0)
    elseif ctrl and pressed(reaper.ImGui_Key_Y) then
        reaper.Main_OnCommandEx(40030, 0, 0)
    elseif ctrl and pressed(reaper.ImGui_Key_Z) then
        reaper.Main_OnCommandEx(40029, 0, 0)
    elseif ctrl and pressed(reaper.ImGui_Key_S) then
        reaper.Main_OnCommandEx(40026, 0, 0)
    elseif not ctrl and not shift and pressed(reaper.ImGui_Key_R) then
        reaper.Main_OnCommandEx(1013, 0, 0)
    end
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

local function fallback_split_text(text, ratio)
  text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return "", "" end
  ratio = math.max(0, math.min(1, ratio))
  local target = #text * ratio
  local candidates = {}

  local search_from = 1
  while true do
    local s, e = text:find("[%.%!%?…]+%s+", search_from)
    if not s then break end
    candidates[#candidates+1] = e
    search_from = e + 1
  end

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

local function split_subtitle_item(sub_item, split_pos)
    local right_item = reaper.SplitMediaItem(sub_item, split_pos)
    if not right_item then return nil end
    
    local notes = subtitle_model.get_string(sub_item, "P_NOTES")
    local words, is_legacy = subtitle_model.get_relative_words(sub_item, false)
    
    local sub_start = reaper.GetMediaItemInfo_Value(sub_item, "D_POSITION")
    local sub_len = reaper.GetMediaItemInfo_Value(sub_item, "D_LENGTH")
    
    if notes ~= "" or #words > 0 then
        local left_text, right_text
        if #words > 0 then
            local cut_offset = split_pos - sub_start
            local original_len = sub_len + reaper.GetMediaItemInfo_Value(right_item, "D_LENGTH")
            
            local left_words = subtitle_model.words_for_range(words, 0, cut_offset, 0)
            local right_words = subtitle_model.words_for_range(words, cut_offset, original_len, cut_offset)
            
            local split_char_pos = find_split_pos_by_words(notes, left_words)
            if split_char_pos > 0 then
                left_text = notes:sub(1, split_char_pos):gsub("%s+$", "")
                right_text = notes:sub(split_char_pos + 1):gsub("^%s+", "")
            else
                left_text = ""
                right_text = notes:gsub("^%s+", "")
            end
            
            subtitle_model.set_relative_words(sub_item, left_words)
            subtitle_model.set_relative_words(right_item, right_words)
        else
            local ratio = (split_pos - sub_start) / (sub_len + reaper.GetMediaItemInfo_Value(right_item, "D_LENGTH"))
            left_text, right_text = fallback_split_text(notes, ratio)
        end
        
        subtitle_model.set_string(sub_item, "P_NOTES", left_text)
        subtitle_model.set_string(right_item, "P_NOTES", right_text)
        
        local take = reaper.GetActiveTake(sub_item)
        if take then
            local short = left_text
            if #short > 40 then short = short:sub(1, 40) .. "..." end
            reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", short, true)
        end
        local take_r = reaper.GetActiveTake(right_item)
        if take_r then
            local short = right_text
            if #short > 40 then short = short:sub(1, 40) .. "..." end
            reaper.GetSetMediaItemTakeInfo_String(take_r, "P_NAME", short, true)
        end
    end
    return right_item
end

local function sync_subtitles_to_audio()
    local sub_track = nil
    for i = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, i)
        local _, name = reaper.GetTrackName(tr)
        if name == "Subtitles" then
            sub_track = tr
            break
        end
    end
    if not sub_track then return end

    -- Collect all subtitle items by group_id
    local subs_by_group = {}
    for i = 0, reaper.CountTrackMediaItems(sub_track) - 1 do
        local item = reaper.GetTrackMediaItem(sub_track, i)
        local group_id = reaper.GetMediaItemInfo_Value(item, "I_GROUPID")
        if group_id > 0 then
            if not subs_by_group[group_id] then subs_by_group[group_id] = {} end
            table.insert(subs_by_group[group_id], item)
        end
    end

    -- Collect all audio items by group_id from non-subtitle tracks
    local audios_by_group = {}
    for i = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, i)
        if tr ~= sub_track then
            for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
                local item = reaper.GetTrackMediaItem(tr, j)
                local group_id = reaper.GetMediaItemInfo_Value(item, "I_GROUPID")
                if group_id > 0 then
                    if not audios_by_group[group_id] then audios_by_group[group_id] = {} end
                    table.insert(audios_by_group[group_id], item)
                end
            end
        end
    end

    local all_groups = {}
    for g, _ in pairs(subs_by_group) do all_groups[g] = true end
    for g, _ in pairs(audios_by_group) do all_groups[g] = true end

    local changed = false

    for g, _ in pairs(all_groups) do
        local subs   = subs_by_group[g]   or {}
        local audios = audios_by_group[g] or {}

        -- Case 1: no audio at all for this group → delete subtitle items
        if #audios == 0 and #subs > 0 then
            if not changed then
                reaper.Undo_BeginBlock()
                reaper.PreventUIRefresh(1)
                changed = true
            end
            for _, sub_item in ipairs(subs) do
                if reaper.ValidatePtr(sub_item, "MediaItem*") then
                    reaper.DeleteTrackMediaItem(sub_track, sub_item)
                end
            end

        -- Case 2: both audio and subtitles exist
        elseif #audios > 0 and #subs > 0 then

            -- Build lookup: for each subtitle item get its time range
            local function overlaps_any_sub(audio_pos, audio_end)
                for _, sub_item in ipairs(subs) do
                    if reaper.ValidatePtr(sub_item, "MediaItem*") then
                        local sp = reaper.GetMediaItemInfo_Value(sub_item, "D_POSITION")
                        local se = sp + reaper.GetMediaItemInfo_Value(sub_item, "D_LENGTH")
                        local ov = math.min(audio_end, se) - math.max(audio_pos, sp)
                        if ov > 0.02 then return true end
                    end
                end
                return false
            end

            -- For each audio item: if it does NOT overlap any subtitle → ungroup it
            for _, audio_item in ipairs(audios) do
                if reaper.ValidatePtr(audio_item, "MediaItem*") then
                    local ap = reaper.GetMediaItemInfo_Value(audio_item, "D_POSITION")
                    local ae = ap + reaper.GetMediaItemInfo_Value(audio_item, "D_LENGTH")
                    if not overlaps_any_sub(ap, ae) then
                        if not changed then
                            reaper.Undo_BeginBlock()
                            reaper.PreventUIRefresh(1)
                            changed = true
                        end
                        -- Remove from group (set group id to 0)
                        reaper.SetMediaItemInfo_Value(audio_item, "I_GROUPID", 0)
                    end
                end
            end
        end
    end

    if changed then
        reaper.PreventUIRefresh(-1)
        reaper.UpdateArrange()
        reaper.Undo_EndBlock("ReaTitles: Ungroup breath/silence items", -1)
    end
end


local function loop()
    cursor = reaper.GetCursorPosition()                             -- cursor position
    playhead = reaper.GetPlayPosition()                             -- playhead position
    ps = reaper.GetPlayState()                                      -- is project playing
    cur_time = reaper.time_precise()                                -- current time
    
    if auto_update_enabled and project_changed() then
        editing_idx = nil
        edit_buf = ""
        edit_focus_pending = false
        edit_had_focus = false
        drag_source_idx = nil
        drag_drop_idx = nil
        drag_offset_y = nil
        drag_start_y = nil
        sync_subtitles_to_audio()
        invalidate_combined_cache()
        update()
    end

    reaper.ImGui_PushFont(ctx, ui_font, ui_scale)

    -- Premium dark theme
    local c = {
        bg        = 0x141420FF,
        child     = 0x111120FF,
        text      = 0xCCCCCCFF,
        dim       = 0x666677FF,
        border    = 0x222235FF,
        accent    = 0x00E5B4FF,
        accent2   = 0x3B82F6FF,
        hover     = 0x1C1C30FF,
        active    = 0x252540FF,
        separator = 0x1A1A2EFF,
        sb_bg     = 0x111120FF,
        sb_grab   = 0x2A2A40FF,
        sb_hov    = 0x3A3A55FF,
        sb_act    = 0x4A4A6AFF,
    }

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(),              theme.bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(),               theme.child)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),                  theme.text)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TextDisabled(),          theme.dim)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),                theme.border)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_BorderShadow(),          0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarBg(),           theme.sb_bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrab(),         theme.sb_grab)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrabHovered(),  theme.sb_hov)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrabActive(),   theme.sb_act)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),                theme.hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(),         theme.active)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),                theme.hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),         theme.active)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),          theme.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),               theme.child)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(),        theme.hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),         theme.active)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(),               theme.bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBg(),               0x0E0E1AFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(),         0x141420FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(),             theme.separator)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SeparatorHovered(),      theme.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SeparatorActive(),       theme.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ResizeGrip(),            0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ResizeGripHovered(),     theme.accent2)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ResizeGripActive(),      theme.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Tab(),                   theme.child)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabHovered(),            theme.active)

    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(),      10)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(),       8)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),       5)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),       0, 0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),         6, 2)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemInnerSpacing(),    4, 4)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarSize(),       8)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarRounding(),   4)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(),    1)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildBorderSize(),     0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(),     0)

    reaper.ImGui_SetNextWindowSize(ctx, 600, 400, reaper.ImGui_Cond_FirstUseEver())
    reaper.ImGui_SetNextWindowPos(ctx, 300, 200, reaper.ImGui_Cond_FirstUseEver())
    local visible, open = reaper.ImGui_Begin(ctx, TITLE, true)
    if visible then
        -- Top menu
        topmenu()

        -- Child window
        if reaper.ImGui_BeginChild(ctx, "child", 0, 0, 0) then
            ui_dimensions.win_width, ui_dimensions.win_height = reaper.ImGui_GetWindowSize(ctx)
            window_hovered = reaper.ImGui_IsWindowHovered(ctx)
            if window_hovered then hovered_time = cur_time end
            src = combo_sources[source_idx]
            if src then
                draw_list()
            else
                reaper.ImGui_TextWrapped( ctx, str.i_empty )
            end

            -- Scroll to central element
            scroll_to_center()

            -- Right-click → context menu
            if window_hovered and reaper.ImGui_IsMouseClicked(ctx, 1) then
                reaper.ImGui_OpenPopup(ctx, "ctx_menu")
                want_context_menu = true
            end
            if want_context_menu then context_menu() end

            reaper.ImGui_EndChild(ctx)
        end
        
        -- debug info
        if debug_mode then
            debug_window()
        end
        forward_reaper_shortcuts()
        reaper.ImGui_End(ctx)
    end

    reaper.ImGui_PopStyleVar(ctx, 11)
    reaper.ImGui_PopStyleColor(ctx, 29)
    reaper.ImGui_PopFont(ctx)
    if open then reaper.defer(loop) end
end

load_settings()
load_language_strings(lang)
migrate_legacy_word_timing()
update()
reaper.atexit(function()
    if custom_picker_undo_open then
        reaper.Undo_EndBlock("ReaTitles: Custom phrase color", -1)
        custom_picker_undo_open = false
    end
end)
reaper.defer(loop)
