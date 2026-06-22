-- @description stomata_notes - Hierarchical metadata notes (Global/Project/Track/Item/FX)
-- @author Stomata Audio
-- @version 0.9.1
-- @build 20260622.1253   -- yyyymmdd.hhmm — bump this on every edit
-- @about
--   Centralized, hierarchical stomata_notes for Reaper.
--   Stores notes at 5 levels: Global (file), Project (ProjExtState),
--   Track, Item, FX (P_EXT keys inside .RPP).
--   Requires: ReaImGui extension (install via ReaPack).

local r = reaper

-- ============================================================
-- CONSTANTS
-- ============================================================
local SCRIPT_NAME    = "stomata_notes"
-- Build version, form yyyymmdd.hhmm.  Keep in sync with the @build header line;
-- bump both every time the script is edited.
local SCRIPT_VERSION = "20260622.1253"
local SCRIPT_URL     = "https://stomataaudio.com/"
local EXT_SECTION  = "stomata_notes"
local NOTE_EXT_KEY = "stomata_notes_note"   -- P_EXT key base

local TAB = { GLOBAL = 1, PROJECT = 2, TRACK = 3, ITEM = 4, FX = 5 }
local TAB_NAMES = { "Global", "Project", "Track", "Item", "FX" }

-- Date/time stamp helpers (requirement: first line of every note file)
local DATE_PREFIX_PAT = "^Last updated: [^\n]*\n\n?"

local function stamp_text(text)
  local clean = (text or ""):gsub(DATE_PREFIX_PAT, "")
  return "Last updated: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n" .. clean
end

local function strip_stamp(text)
  return (text or ""):gsub(DATE_PREFIX_PAT, "")
end

-- ============================================================
-- STATE
-- ============================================================
local ctx
local win_open       = true
local active_tab     = TAB.PROJECT
local request_tab    = nil    -- persists until ImGui confirms the switch via BeginTabItem

local note_bufs  = { "", "", "", "", "" }   -- edit buffers per tab
local dirty      = { false, false, false, false, false }

local cur_track      = nil
local cur_item       = nil
local cur_fx_track   = nil
local cur_fx_idx     = -1

-- When the user clicks a note in the list view we "lock" that tab so
-- sync_selections() won't immediately overwrite cur_* back to nil.
-- The lock clears automatically the moment a real Reaper selection exists.
local list_lock  = { [TAB.TRACK] = false, [TAB.ITEM] = false, [TAB.FX] = false }

-- Set to true by a double-click on a Track/Item/FX tab to force the list view
-- even when cur_* is non-nil.  Cleared only when the Reaper selection changes.
local force_list = { [TAB.TRACK] = false, [TAB.ITEM] = false, [TAB.FX] = false }

-- Word-wrap dual-mode editor state.
-- editing_tab: which tab is showing InputTextMultiline (nil = all showing wrapped read view)
-- want_focus:  true for one frame to move keyboard focus into the InputTextMultiline
local editing_tab  = nil
local want_focus   = false

local filter_buf     = ""

-- True only when the project has both a name and a folder (i.e. has been saved).
-- When false, every project-scoped tab (Project/Track/Item/FX) is locked and
-- only the Global tab is usable, so no orphaned "unnamed_*" sidecars get written.
-- Recomputed every frame so saving the project unlocks the tabs live.
local project_ready  = false

-- One-shot guard so the "please save the project" advisory box only appears once
-- per locked session, not on every frame.
local warned_unsaved = false

-- Set true when "About Stomata Notes" is chosen; opens the About popup next frame.
local show_about     = false

-- External editor: tab → { path = string, last = string }
local ext_watch = {}

-- Forward declaration: defined after get_ext_filepath (which it depends on).
local write_note_file

-- ============================================================
-- STORAGE: Global (plain .txt file in Reaper resource path)
-- ============================================================

local function global_path()
  -- Global notes are cross-project and live in Reaper's resource path, not the project folder.
  return r.GetResourcePath() .. "/stomata_notes_global.txt"
end

-- RTF sidecar for the global note.  The .txt above stays the canonical store
-- (so the global note remains readable without this script); the .rtf is the
-- rich working copy used by the external editor, mirroring the other tabs.
local function global_rtf_path()
  return r.GetResourcePath() .. "/stomata_notes_global.rtf"
end

local function load_global()
  local f = io.open(global_path(), "r")
  if not f then return "" end
  local s = f:read("*a")
  f:close()
  return strip_stamp(s or "")   -- strip timestamp so buffer stays clean
end

local function save_global(text)
  local f = io.open(global_path(), "w")
  if f then f:write(stamp_text(text)); f:close() end  -- always write fresh timestamp
end

-- ============================================================
-- STORAGE: Project
--   Primary:  native GetSetProjectNotes (View > Project Notes)
--   Fallback: ProjExtState (legacy / cross-project safety net)
-- ============================================================

local function load_project()
  local _, native = r.GetSetProjectNotes(0, false, "")
  if native and native ~= "" then return native end
  local ok, val = r.GetProjExtState(0, EXT_SECTION, "note")
  return (ok == 1) and val or ""
end

local function save_project(text)
  r.GetSetProjectNotes(0, true, text)          -- native View > Project Notes
  r.SetProjExtState(0, EXT_SECTION, "note", text)
end

-- ============================================================
-- STORAGE: Track
--   Primary:  native P_NOTES key (Track Properties Notes field)
--   Fallback: P_EXT inside .RPP (legacy)
-- ============================================================

local function load_track(track)
  if not track then return "" end
  local _, native = r.GetSetMediaTrackInfo_String(track, "P_NOTES", "", false)
  if native and native ~= "" then return native end
  local _, val = r.GetSetMediaTrackInfo_String(track, "P_EXT:" .. NOTE_EXT_KEY, "", false)
  return val or ""
end

local function save_track(track, text)
  if not track then return end
  r.GetSetMediaTrackInfo_String(track, "P_NOTES", text, true)
  r.GetSetMediaTrackInfo_String(track, "P_EXT:" .. NOTE_EXT_KEY, text, true)
end

-- ============================================================
-- STORAGE: Item
--   Primary:  native P_NOTES key (Item Properties Notes field)
--   Fallback: P_EXT inside .RPP (legacy)
-- ============================================================

local function load_item(item)
  if not item then return "" end
  local _, native = r.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
  if native and native ~= "" then return native end
  local _, val = r.GetSetMediaItemInfo_String(item, "P_EXT:" .. NOTE_EXT_KEY, "", false)
  return val or ""
end

local function save_item(item, text)
  if not item then return end
  r.GetSetMediaItemInfo_String(item, "P_NOTES", text, true)
  r.GetSetMediaItemInfo_String(item, "P_EXT:" .. NOTE_EXT_KEY, text, true)
end

-- ============================================================
-- STORAGE: FX (P_EXT on track, keyed by FX slot index)
-- ============================================================

local function fx_pext_key(idx)
  return NOTE_EXT_KEY .. "_fx" .. tostring(idx)
end

local function load_fx(track, idx)
  if not track or idx < 0 then return "" end
  local _, val = r.GetSetMediaTrackInfo_String(track, "P_EXT:" .. fx_pext_key(idx), "", false)
  return val or ""
end

local function save_fx(track, idx, text)
  if not track or idx < 0 then return end
  r.GetSetMediaTrackInfo_String(track, "P_EXT:" .. fx_pext_key(idx), text, true)
end

-- ============================================================
-- BUFFER HELPERS: load/save by tab index
-- ============================================================

local function load_buf(tab)
  if     tab == TAB.GLOBAL   then note_bufs[tab] = load_global()
  elseif tab == TAB.PROJECT  then note_bufs[tab] = load_project()
  elseif tab == TAB.TRACK    then note_bufs[tab] = load_track(cur_track)
  elseif tab == TAB.ITEM     then note_bufs[tab] = load_item(cur_item)
  elseif tab == TAB.FX       then note_bufs[tab] = load_fx(cur_fx_track, cur_fx_idx)
  end
  dirty[tab] = false
end

local function save_buf(tab)
  r.Undo_BeginBlock()
  if     tab == TAB.GLOBAL   then save_global(note_bufs[tab])
  elseif tab == TAB.PROJECT  then save_project(note_bufs[tab])
  elseif tab == TAB.TRACK    then save_track(cur_track, note_bufs[tab])
  elseif tab == TAB.ITEM     then save_item(cur_item, note_bufs[tab])
  elseif tab == TAB.FX       then save_fx(cur_fx_track, cur_fx_idx, note_bufs[tab])
  end
  -- Also write a .txt file to stomata_notes/ so notes are visible on disk.
  -- Global has its own file path; the other four tabs use write_note_file.
  if tab ~= TAB.GLOBAL then write_note_file(tab, note_bufs[tab]) end
  r.Undo_EndBlock(SCRIPT_NAME .. ": save " .. (TAB_NAMES[tab] or "note"), -1)
  r.MarkProjectDirty(0)
  dirty[tab] = false
end

local function save_all_dirty()
  for i = 1, 5 do
    if dirty[i] then save_buf(i) end
  end
end

-- ============================================================
-- SELECTION HELPERS
-- ============================================================

local function get_focused_fx_info()
  local retval, track_num, item_num, fx_num = r.GetFocusedFX()
  if retval == 1 then
    local track = (track_num == 0) and r.GetMasterTrack(0) or r.GetTrack(0, track_num - 1)
    return track, fx_num
  end
  return nil, -1
end

local function determine_initial_tab()
  local fx_t, fx_i = get_focused_fx_info()
  if fx_t and fx_i >= 0 then
    cur_fx_track = fx_t
    cur_fx_idx   = fx_i
    return TAB.FX
  end
  local item = r.GetSelectedMediaItem(0, 0)
  if item then
    cur_item = item
    return TAB.ITEM
  end
  local track = r.GetSelectedTrack(0, 0)
  if track then
    cur_track = track
    return TAB.TRACK
  end
  return TAB.PROJECT
end

-- ============================================================
-- EXTERNAL EDITOR: launch system text app, watch for changes
-- ============================================================

local function get_project_dir()
  local _, proj_file = r.EnumProjects(-1, "")
  if proj_file and proj_file ~= "" then
    return proj_file:match("(.+)[/\\][^/\\]+$") or r.GetResourcePath()
  end
  return r.GetResourcePath()
end

local function safe_fname(s)
  return (s:gsub('[/\\:*?"<>|]', "_"):gsub("%s+", "_")):sub(1, 48)
end

local function get_ext_filepath(tab)
  -- Note: TAB.GLOBAL is handled separately via global_path().
  local dir = get_project_dir() .. "/stomata_notes"
  r.RecursiveCreateDirectory(dir, 0)
  -- All filenames are prefixed with the project name (requirement #2).
  local pn          = r.GetProjectName(0, ""):gsub("%.rpp$", "")
  local proj_prefix = safe_fname(pn ~= "" and pn or "unnamed") .. "_"
  local stem
  if tab == TAB.PROJECT then
    stem = "project"
  elseif tab == TAB.TRACK then
    if not cur_track then return nil end
    local _, tn = r.GetTrackName(cur_track)
    local ti    = r.GetMediaTrackInfo_Value(cur_track, "IP_TRACKNUMBER")
    stem = "track_" .. string.format("%02d", ti) .. "_" .. safe_fname(tn or "track")
  elseif tab == TAB.ITEM then
    if not cur_item then return nil end
    local tk    = r.GetActiveTake(cur_item)
    local iname = tk and r.GetTakeName(tk) or "item"
    local pos   = r.GetMediaItemInfo_Value(cur_item, "D_POSITION")
    stem = "item_" .. string.format("%.2f", pos) .. "_" .. safe_fname(iname)
  elseif tab == TAB.FX then
    if not cur_fx_track or cur_fx_idx < 0 then return nil end
    local _, fn = r.TrackFX_GetFXName(cur_fx_track, cur_fx_idx, "")
    stem = "fx_" .. string.format("%02d", cur_fx_idx) .. "_" .. safe_fname(fn or "fx")
  end
  return stem and (dir .. "/" .. proj_prefix .. stem .. ".rtf") or nil
end

-- Write a plain .txt sidecar to stomata_notes/ on every save (requirement #1).
-- Assigned here (not declared with 'local') so the forward declaration above
-- is filled in once get_ext_filepath is available.
write_note_file = function(tab, text)
  -- Safety net: never write project-scoped sidecars for an unsaved project,
  -- otherwise they land in the resource path as orphaned "unnamed_*" files.
  -- (Global has its own path and is handled elsewhere, so it's exempt.)
  if not project_ready and tab ~= TAB.GLOBAL then return end
  local path = get_ext_filepath(tab)
  if not path then return end
  path = path:gsub("%.rtf$", ".txt")   -- store as plain text
  local f = io.open(path, "w")
  if f then f:write(stamp_text(text)); f:close() end
end

-- POSIX sh: wrap path in single quotes, escaping embedded single quotes.
local function sh_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Launch the file in the system text app and start a background process that
-- writes `sentinel` once the document is closed, so the frame loop can
-- detect the app exit without polling the OS on every frame.
local function launch_ext_app(path, sentinel)
  os.remove(sentinel)   -- clear any stale sentinel from a previous run

  local os_name = r.GetOS()

  if os_name:find("OSX") or os_name:find("macOS") then
    -- `open -W` blocks until the document window is closed (not the whole app).
    os.execute(string.format(
      "(open -W %s; touch %s) &",
      sh_quote(path), sh_quote(sentinel)))

  elseif os_name:find("Win") then
    -- Write a tiny PowerShell script that opens the file, waits until the
    -- associated app releases its file lock (document closed), then writes
    -- the sentinel.  Single-quote any quotes in paths for PS1 string literals.
    local wp  = path:gsub("/", "\\")
    local ws  = sentinel:gsub("/", "\\")
    local ps1 = r.GetResourcePath() .. "\\stomata_watcher.ps1"
    local f   = io.open(ps1, "w")
    if f then
      f:write(string.format(
        "$p='%s';$s='%s'\r\n" ..
        "Start-Process $p\r\n" ..
        "Start-Sleep 3\r\n" ..
        "$l=$true\r\n" ..
        "while($l){Start-Sleep 1;" ..
        "try{$h=[IO.File]::Open($p,'Open','ReadWrite','None');$h.Close();$l=$false}" ..
        "catch{}}\r\n" ..
        "New-Item -Force -ItemType File $s|Out-Null\r\n",
        wp:gsub("'","''"), ws:gsub("'","''")))
      f:close()
      os.execute(string.format(
        'start "" powershell -WindowStyle Hidden -NoProfile ' ..
        '-ExecutionPolicy Bypass -File "%s"', ps1))
    else
      os.execute('start "" "' .. wp .. '"')   -- fallback: open without sentinel
    end

  else
    -- Linux: xdg-open is fire-and-forget; poll lsof until the file handle
    -- is gone (app closed the document), then write the sentinel.
    os.execute(string.format(
      "(xdg-open %s; sleep 3; " ..
      "while lsof %s >/dev/null 2>&1; do sleep 2; done; " ..
      "touch %s) &",
      sh_quote(path), sh_quote(path), sh_quote(sentinel)))
  end
end

-- ── RTF ↔ plain-text conversion ──────────────────────────────

-- Wrap plain text in minimal valid RTF 1.
local function plain_to_rtf(text)
  local s = (text or "")
    :gsub("\\", "\\\\")
    :gsub("{",  "\\{")
    :gsub("}",  "\\}")
    :gsub("\r\n", "\\par\r\n")
    :gsub("\r",   "\\par\r\n")
    :gsub("\n",   "\\par\r\n")
  return "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0\\fswiss\\fcharset0 Helvetica;}}\r\n"
      .. "\\pard\\f0\\fs24 " .. s .. "}"
end

-- Token-based RTF → plain text.  Handles TextEdit (macOS) and
-- WordPad (Windows) output correctly.
local function rtf_to_plain(rtf)
  if not rtf or rtf == "" then return "" end
  if not rtf:match("^{\\rtf") then return rtf end   -- not RTF, pass through

  local out   = {}
  local i     = 1
  local n     = #rtf
  local depth = 0
  local skip  = 0   -- depth at which we entered a discarded group

  -- Groups whose entire subtree we discard
  local SKIP_WORDS = {
    fonttbl=true, colortbl=true, stylesheet=true, info=true,
    pict=true, object=true, header=true, footer=true,
  }

  while i <= n do
    local c = rtf:sub(i, i)

    if c == "{" then
      depth = depth + 1
      i = i + 1

    elseif c == "}" then
      if skip == depth then skip = 0 end
      depth = depth - 1
      i = i + 1

    elseif c == "\\" then
      i = i + 1
      if i > n then break end
      local nc = rtf:sub(i, i)

      -- Escaped literal chars: \\ \{ \}
      if nc == "\\" or nc == "{" or nc == "}" then
        if skip == 0 then out[#out+1] = nc end
        i = i + 1

      -- Hex-encoded char: \'xx
      elseif nc == "'" then
        if skip == 0 then
          local code = tonumber(rtf:sub(i+1, i+2), 16)
          if code then out[#out+1] = string.char(code) end
        end
        i = i + 3

      -- \* marks the rest of the enclosing group as ignorable
      elseif nc == "*" then
        skip = depth
        i = i + 1

      -- Backslash-newline = line break (macOS TextEdit style)
      elseif nc == "\n" or nc == "\r" then
        if skip == 0 then out[#out+1] = "\n" end
        if nc == "\r" and rtf:sub(i+1, i+1) == "\n" then i = i + 1 end
        i = i + 1

      -- Control word: \letters[digits][ ]
      elseif nc:match("[%a]") then
        local j = i
        while j <= n and rtf:sub(j, j):match("[%a]") do j = j + 1 end
        local word = rtf:sub(i, j-1)
        i = j
        local num_s = rtf:match("^%-?%d+", i) or ""
        i = i + #num_s
        if rtf:sub(i, i) == " " then i = i + 1 end   -- delimiter

        if SKIP_WORDS[word] then
          skip = depth - 1   -- discard this group's content
        elseif skip == 0 then
          if word == "par" or word == "page" then
            out[#out+1] = "\n"
          elseif word == "line" then
            out[#out+1] = "\n"
          elseif word == "tab" then
            out[#out+1] = "\t"
          elseif word == "u" then
            -- Unicode scalar: \uN followed by replacement char
            local code = tonumber(num_s) or 0
            if code < 0 then code = code + 65536 end
            if code < 0x80 then
              out[#out+1] = string.char(code)
            elseif code < 0x800 then
              out[#out+1] = string.char(
                0xC0 + math.floor(code/64),
                0x80 + (code % 64))
            else
              out[#out+1] = string.char(
                0xE0 + math.floor(code/4096),
                0x80 + math.floor((code%4096)/64),
                0x80 + (code % 64))
            end
          end
          -- All other control words (b, i, fs, cf, pard, …) are silently dropped
        end

      else
        i = i + 1   -- unknown backslash sequence
      end

    -- Bare CR/LF inside RTF stream is whitespace, not content (\par is)
    elseif c == "\r" or c == "\n" then
      i = i + 1

    else
      if skip == 0 then out[#out+1] = c end
      i = i + 1
    end
  end

  local result = table.concat(out)
  return result:match("^%s*(.-)%s*$") or result
end

-- Returns true when a persisted RTF file exists for the tab's current selection.
local function rtf_file_exists(tab)
  -- Global keeps its RTF beside the resource-path .txt, not in get_ext_filepath.
  local path = (tab == TAB.GLOBAL) and global_rtf_path() or get_ext_filepath(tab)
  if not path then return false end
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

-- ── Editor open / change detection ───────────────────────────

local function open_in_ext_editor(tab)
  -- Every tab edits an .rtf working copy in the external editor.  Global keeps
  -- its canonical text in stomata_notes_global.txt (written by save_global) and
  -- uses an .rtf sidecar here, just like the other tabs.
  local path, is_txt
  if tab == TAB.GLOBAL then
    path   = global_rtf_path()
    is_txt = false
  else
    path   = get_ext_filepath(tab)
    is_txt = false
  end
  if not path then
    r.ShowMessageBox(
      "No selection for this level.\nSelect a track / item / FX first.",
      SCRIPT_NAME, 0)
    return
  end

  local sentinel = path .. ".~done"

  local existing = io.open(path, "r")
  if existing then
    -- File already exists: open it as-is so no external edits are ever lost.
    -- (RTF re-wrapping would mangle TextEdit's formatting; leaving it alone is safest.)
    local content = existing:read("*a"); existing:close()
    ext_watch[tab] = { path = path, sentinel = sentinel, last = content }
  else
    -- New file: seed from the current buffer with a fresh timestamp.
    local stamped      = stamp_text(note_bufs[tab])
    local file_content = is_txt and stamped or plain_to_rtf(stamped)
    local f = io.open(path, "w")
    if not f then
      r.ShowMessageBox("Could not write file:\n" .. path, SCRIPT_NAME, 0)
      return
    end
    f:write(file_content); f:close()
    ext_watch[tab] = { path = path, sentinel = sentinel, last = file_content }
  end

  launch_ext_app(path, sentinel)
end

local function check_ext_changes()
  local to_stop = {}

  for tab, w in pairs(ext_watch) do
    -- Check whether the app has closed by looking for the sentinel file.
    local sf = io.open(w.sentinel, "r")
    if sf then
      sf:close()
      os.remove(w.sentinel)
      -- Final read: capture any changes made right before the editor closed.
      local ff = io.open(w.path, "r")
      if ff then
        local final = ff:read("*a"); ff:close()
        if final ~= w.last then
          local is_txt_f = w.path:match("%.txt$")
          note_bufs[tab] = strip_stamp(is_txt_f and final or rtf_to_plain(final))
          dirty[tab]     = true
          save_buf(tab)
        end
      end
      to_stop[#to_stop + 1] = tab
    else
      -- App still open: check for content changes made by the user.
      local f = io.open(w.path, "r")
      if f then
        local content = f:read("*a"); f:close()
        if content ~= w.last then
          w.last         = content
          local is_txt   = w.path:match("%.txt$")
          -- Strip timestamp from buffer so the in-app view stays clean.
          note_bufs[tab] = strip_stamp(is_txt and content or rtf_to_plain(content))
          dirty[tab]     = true
          save_buf(tab)
        end
      end
    end
  end

  -- Remove watchers for closed apps outside the iteration loop.
  for _, tab in ipairs(to_stop) do
    ext_watch[tab] = nil
  end
end

-- ============================================================
-- AUTO-SYNC: detect selection changes each frame
-- ============================================================

local function sync_selections()
  if r.ImGui_IsAnyItemActive(ctx) then return end

  local fx_t, fx_i = get_focused_fx_info()
  if fx_t ~= nil then list_lock[TAB.FX] = false end      -- real selection → release lock
  if not list_lock[TAB.FX] then
    if fx_t ~= cur_fx_track or fx_i ~= cur_fx_idx then
      force_list[TAB.FX] = false                          -- selection changed → dismiss list override
      if active_tab == TAB.FX and dirty[TAB.FX] then save_buf(TAB.FX) end
      cur_fx_track = fx_t
      cur_fx_idx   = fx_i
      if active_tab == TAB.FX then load_buf(TAB.FX) end
    end
  end

  local track = r.GetSelectedTrack(0, 0)
  if track ~= nil then list_lock[TAB.TRACK] = false end   -- real selection → release lock
  if not list_lock[TAB.TRACK] then
    if track ~= cur_track then
      force_list[TAB.TRACK] = false                       -- selection changed → dismiss list override
      if active_tab == TAB.TRACK and dirty[TAB.TRACK] then save_buf(TAB.TRACK) end
      cur_track = track
      if active_tab == TAB.TRACK then load_buf(TAB.TRACK) end
    end
  end

  local item = r.GetSelectedMediaItem(0, 0)
  if item ~= nil then list_lock[TAB.ITEM] = false end     -- real selection → release lock
  if not list_lock[TAB.ITEM] then
    if item ~= cur_item then
      force_list[TAB.ITEM] = false                        -- selection changed → dismiss list override
      if active_tab == TAB.ITEM and dirty[TAB.ITEM] then save_buf(TAB.ITEM) end
      cur_item = item
      if active_tab == TAB.ITEM then load_buf(TAB.ITEM) end
    end
  end
end

-- ============================================================
-- Format seconds as m:ss.xx  (e.g. 0:04.20, 1:23.07)
local function fmt_time(secs)
  local m = math.floor(secs / 60)
  local s = secs - m * 60
  return string.format("%d:%05.2f", m, s)
end

-- UI: Note editor area
-- ============================================================

local function draw_editor(ctx, tab)
  local avail_w, avail_h = r.ImGui_GetContentRegionAvail(ctx)
  avail_h = avail_h - 2

  -- ---- RTF lock: if a persisted RTF file exists, block in-app editing ----
  if rtf_file_exists(tab) then
    editing_tab = nil   -- ensure we never enter edit mode for this tab
    local warn_h = 52
    r.ImGui_BeginChild(ctx, "##rd_rtf_" .. tab, avail_w, avail_h - warn_h, 0)
    if note_bufs[tab] == "" then
      r.ImGui_TextDisabled(ctx, "(no content loaded yet)")
    else
      r.ImGui_TextWrapped(ctx, note_bufs[tab])
    end
    r.ImGui_EndChild(ctx)

    r.ImGui_Spacing(ctx)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFF9900FF)
    r.ImGui_TextWrapped(ctx,
      "An RTF file exists for this note — in-app editing is disabled.\n" ..
      "Use  Open in Editor  above to edit it.")
    r.ImGui_PopStyleColor(ctx, 1)
    return
  end

  if editing_tab == tab then
    -- ---- Edit mode: standard InputTextMultiline ----
    if want_focus then
      r.ImGui_SetKeyboardFocusHere(ctx)
      want_focus = false
    end
    local flags = r.ImGui_InputTextFlags_AllowTabInput()
    local changed, new_val = r.ImGui_InputTextMultiline(ctx,
      "##ed_" .. tab, note_bufs[tab], avail_w, avail_h, flags)
    if changed then
      note_bufs[tab] = new_val
      dirty[tab] = true
    end
    -- Return to word-wrap read mode when the editor loses focus
    if r.ImGui_IsItemDeactivated(ctx) then
      editing_tab = nil
    end
  else
    -- ---- Read / word-wrap mode: TextWrapped display, click to edit ----
    r.ImGui_BeginChild(ctx, "##rd_" .. tab, avail_w, avail_h, 0)
    if note_bufs[tab] == "" then
      r.ImGui_TextDisabled(ctx, "(empty — click to edit)")
    else
      r.ImGui_TextWrapped(ctx, note_bufs[tab])
    end
    -- Single click anywhere in the read area activates the editor
    if r.ImGui_IsWindowHovered(ctx) and r.ImGui_IsMouseClicked(ctx, 0) then
      editing_tab = tab
      want_focus  = true
    end
    r.ImGui_EndChild(ctx)
  end
end

-- ============================================================
-- UI: List view
-- ============================================================

local function draw_list_view(ctx, tab, entries, on_click)
  r.ImGui_TextDisabled(ctx, "No note for current selection. All notes in project:")
  r.ImGui_Spacing(ctx)

  r.ImGui_SetNextItemWidth(ctx, -1)
  local fch, fbuf = r.ImGui_InputTextWithHint(ctx, "##flt_" .. tab, "Filter notes...", filter_buf)
  if fch then filter_buf = fbuf end
  r.ImGui_Separator(ctx)

  local lo = filter_buf:lower()
  local avail_w, avail_h = r.ImGui_GetContentRegionAvail(ctx)

  r.ImGui_BeginChild(ctx, "##lst_" .. tab, avail_w, avail_h, 0)
  local count = 0
  for _, e in ipairs(entries) do
    local note_text = e.note or ""
    local matches = lo == "" or
      e.label:lower():find(lo, 1, true) or
      note_text:lower():find(lo, 1, true)
    if matches then
      count = count + 1
      local preview = note_text:gsub("\n", " "):sub(1, 60)
      if #note_text > 60 then preview = preview .. "…" end
      local full_lbl = string.format("%s\n  %s##sl%d", e.label, preview, count)
      if r.ImGui_Selectable(ctx, full_lbl, false, r.ImGui_SelectableFlags_AllowDoubleClick()) then
        on_click(e)
      end
      r.ImGui_Separator(ctx)
    end
  end
  if count == 0 then
    r.ImGui_TextDisabled(ctx, "(no matches)")
  end
  r.ImGui_EndChild(ctx)
end

-- ============================================================
-- UI: Tab content draw functions
-- ============================================================

local function draw_global(ctx)
  draw_editor(ctx, TAB.GLOBAL)
end

local function draw_project(ctx)
  local proj_name = r.GetProjectName(0, "")
  if proj_name ~= "" then
    r.ImGui_TextDisabled(ctx, "Project: " .. proj_name)
    r.ImGui_Spacing(ctx)
  end
  draw_editor(ctx, TAB.PROJECT)
end

local function draw_track(ctx)
  if cur_track and not force_list[TAB.TRACK] then
    local _, tname = r.GetTrackName(cur_track)
    r.ImGui_TextDisabled(ctx, "Track: " .. (tname or "?"))
    r.ImGui_Spacing(ctx)
    draw_editor(ctx, TAB.TRACK)
  else
    local entries = {}
    for i = 0, r.CountTracks(0) - 1 do
      local tr = r.GetTrack(0, i)
      local note = load_track(tr)
      if note ~= "" then
        local _, nm = r.GetTrackName(tr)
        table.insert(entries, { label = nm or ("Track " .. (i+1)), track = tr, note = note })
      end
    end
    if #entries == 0 then
      r.ImGui_TextDisabled(ctx, "No track selected and no track notes exist in this project.")
    else
      draw_list_view(ctx, TAB.TRACK, entries, function(e)
        list_lock[TAB.TRACK]  = true
        force_list[TAB.TRACK] = false
        cur_track             = e.track
        note_bufs[TAB.TRACK]  = e.note
        dirty[TAB.TRACK]      = false
      end)
    end
  end
end

local function draw_item(ctx)
  if cur_item and not force_list[TAB.ITEM] then
    local take  = r.GetActiveTake(cur_item)
    local iname = take and r.GetTakeName(take) or "Untitled Item"
    r.ImGui_TextDisabled(ctx, "Item: " .. iname)
    r.ImGui_Spacing(ctx)
    draw_editor(ctx, TAB.ITEM)
  else
    local entries = {}
    for ti = 0, r.CountTracks(0) - 1 do
      local tr = r.GetTrack(0, ti)
      local _, tnm = r.GetTrackName(tr)
      for ii = 0, r.CountTrackMediaItems(tr) - 1 do
        local it   = r.GetTrackMediaItem(tr, ii)
        local note = load_item(it)
        if note ~= "" then
          local tk    = r.GetActiveTake(it)
          local itnam = tk and r.GetTakeName(tk) or ("Item " .. (ii + 1))
          local pos   = r.GetMediaItemInfo_Value(it, "D_POSITION")
          table.insert(entries, {
            label = (tnm or "?") .. " › " .. itnam .. "  [" .. fmt_time(pos) .. "]",
            item  = it,
            note  = note,
          })
        end
      end
    end
    if #entries == 0 then
      r.ImGui_TextDisabled(ctx, "No item selected and no item notes exist in this project.")
    else
      draw_list_view(ctx, TAB.ITEM, entries, function(e)
        list_lock[TAB.ITEM]  = true
        force_list[TAB.ITEM] = false
        cur_item             = e.item
        note_bufs[TAB.ITEM]  = e.note
        dirty[TAB.ITEM]      = false
      end)
    end
  end
end

local function draw_fx(ctx)
  if cur_fx_track and cur_fx_idx >= 0 and not force_list[TAB.FX] then
    local _, tname = r.GetTrackName(cur_fx_track)
    local _, fname = r.TrackFX_GetFXName(cur_fx_track, cur_fx_idx, "")
    r.ImGui_TextDisabled(ctx, "FX: " .. (fname or "?") .. "  (" .. (tname or "?") .. ")")
    r.ImGui_Spacing(ctx)
    draw_editor(ctx, TAB.FX)
  else
    local entries = {}
    local all_tracks = { r.GetMasterTrack(0) }
    for i = 0, r.CountTracks(0) - 1 do
      table.insert(all_tracks, r.GetTrack(0, i))
    end
    for _, tr in ipairs(all_tracks) do
      local _, tnm = r.GetTrackName(tr)
      for fi = 0, r.TrackFX_GetCount(tr) - 1 do
        local note = load_fx(tr, fi)
        if note ~= "" then
          local _, fnm = r.TrackFX_GetFXName(tr, fi, "")
          table.insert(entries, {
            label  = (tnm or "?") .. " › " .. string.format("[%02d] ", fi + 1) .. (fnm or "FX"),
            track  = tr,
            fx_idx = fi,
            note   = note,
          })
        end
      end
    end
    if #entries == 0 then
      r.ImGui_TextDisabled(ctx, "No FX focused and no FX notes exist in this project.")
    else
      draw_list_view(ctx, TAB.FX, entries, function(e)
        list_lock[TAB.FX]  = true
        force_list[TAB.FX] = false
        cur_fx_track       = e.track
        cur_fx_idx         = e.fx_idx
        note_bufs[TAB.FX]  = e.note
        dirty[TAB.FX]      = false
      end)
    end
  end
end

-- ============================================================
-- UI: "New Note" contextual action
-- ============================================================

local function do_new_note()
  if active_tab == TAB.GLOBAL or active_tab == TAB.PROJECT then
    note_bufs[active_tab] = ""
    dirty[active_tab] = true
  elseif active_tab == TAB.TRACK then
    if cur_track then
      note_bufs[TAB.TRACK] = ""
      dirty[TAB.TRACK] = true
    else
      r.ShowMessageBox("Select a track first to create a track note.", SCRIPT_NAME, 0)
    end
  elseif active_tab == TAB.ITEM then
    if cur_item then
      note_bufs[TAB.ITEM] = ""
      dirty[TAB.ITEM] = true
    else
      r.ShowMessageBox("Select a media item first to create an item note.", SCRIPT_NAME, 0)
    end
  elseif active_tab == TAB.FX then
    if cur_fx_track and cur_fx_idx >= 0 then
      note_bufs[TAB.FX] = ""
      dirty[TAB.FX] = true
    else
      r.ShowMessageBox("Focus an FX plugin window first to create an FX note.", SCRIPT_NAME, 0)
    end
  end
end

-- ============================================================
-- DELETE: remove the selected note (RTF + plain-text sidecar)
-- ============================================================

-- Deletes both on-disk versions of the active tab's selected note and
-- clears the in-memory buffer + embedded REAPER note so it isn't restored
-- on the next save.  Prompts for Yes/No confirmation before doing anything.
local function delete_current_note(tab)
  -- Resolve the file paths for this tab's current selection.
  local rtf_path, txt_path
  if tab == TAB.GLOBAL then
    -- Global keeps a canonical .txt plus an .rtf working-copy sidecar.
    txt_path = global_path()
    rtf_path = global_rtf_path()
  else
    rtf_path = get_ext_filepath(tab)        -- nil if nothing is selected
    if rtf_path then txt_path = rtf_path:gsub("%.rtf$", ".txt") end
  end

  if not rtf_path and not txt_path then
    r.ShowMessageBox(
      "No note is selected to delete.\nSelect a track / item / FX first.",
      SCRIPT_NAME, 0)
    return
  end

  -- Confirmation step (4 = Yes/No; returns 6 for Yes).
  local choice = r.ShowMessageBox(
    "Delete the " .. (TAB_NAMES[tab] or "selected") .. " note?\n\n" ..
    "This permanently removes both the .rtf and .txt files and clears " ..
    "the note text. This cannot be undone.",
    SCRIPT_NAME .. ": Delete Note", 4)
  if choice ~= 6 then return end

  -- Remove the on-disk files.
  if rtf_path then os.remove(rtf_path) end
  if txt_path then os.remove(txt_path) end

  -- Stop watching the file and clear the editor buffer.
  ext_watch[tab] = nil
  note_bufs[tab] = ""
  dirty[tab]     = false

  -- Clear the embedded REAPER note so the deletion sticks (otherwise the
  -- note would reload from project/track/item/FX state on the next select).
  if     tab == TAB.PROJECT then save_project("")
  elseif tab == TAB.TRACK   then if cur_track then save_track(cur_track, "") end
  elseif tab == TAB.ITEM    then if cur_item  then save_item(cur_item, "") end
  elseif tab == TAB.FX      then
    if cur_fx_track and cur_fx_idx >= 0 then save_fx(cur_fx_track, cur_fx_idx, "") end
  end
  -- (Global lives only in the .txt file just removed; nothing more to clear.)
end

-- ============================================================
-- MAIN DEFERRED FRAME
-- ============================================================

local function frame()
  if not win_open then return end

  -- Re-evaluate save state every frame so the lock tracks reality: saving the
  -- project unlocks the tabs live; starting a new untitled project re-locks.
  local was_ready = project_ready
  local why_locked
  project_ready, why_locked = project_is_ready()

  if project_ready and not was_ready then
    -- Just got saved: clear the one-shot advisory so a future re-lock re-warns.
    warned_unsaved = false
  elseif not project_ready and was_ready then
    -- Just became unsaved again (e.g. New Project): retreat to the Global tab.
    if dirty[active_tab] then save_buf(active_tab) end
    active_tab  = TAB.GLOBAL
    request_tab = TAB.GLOBAL
    load_buf(TAB.GLOBAL)
  end

  sync_selections()
  check_ext_changes()

  r.ImGui_SetNextWindowSize(ctx, 660, 540, r.ImGui_Cond_FirstUseEver())

  local win_flags = r.ImGui_WindowFlags_MenuBar()
  local visible, still_open = r.ImGui_Begin(ctx, SCRIPT_NAME, true, win_flags)
  win_open = still_open

  if visible then
    if r.ImGui_BeginMenuBar(ctx) then
      if r.ImGui_BeginMenu(ctx, "File") then
        if r.ImGui_MenuItem(ctx, "Save Current Tab") then
          save_buf(active_tab)
        end
        if r.ImGui_MenuItem(ctx, "Save All") then
          save_all_dirty()
        end
        r.ImGui_Separator(ctx)
        if r.ImGui_MenuItem(ctx, "Delete Note") then
          delete_current_note(active_tab)
        end
        r.ImGui_Separator(ctx)
        if r.ImGui_MenuItem(ctx, "About Stomata Notes") then
          show_about = true
        end
        r.ImGui_Separator(ctx)
        if r.ImGui_MenuItem(ctx, "Close") then
          win_open = false
        end
        r.ImGui_EndMenu(ctx)
      end
      if r.ImGui_BeginMenu(ctx, "Jump To") then
        for i, name in ipairs(TAB_NAMES) do
          local enabled = project_ready or i == TAB.GLOBAL
          if r.ImGui_MenuItem(ctx, name, nil, false, enabled) then
            if dirty[active_tab] then save_buf(active_tab) end
            active_tab  = i
            request_tab = i
            load_buf(i)
          end
        end
        r.ImGui_EndMenu(ctx)
      end
      r.ImGui_EndMenuBar(ctx)
    end

    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x228844FF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x33AA66FF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(),  0x11662FFF)
    if r.ImGui_Button(ctx, "  + New Note  ") then
      do_new_note()
    end
    r.ImGui_PopStyleColor(ctx, 3)

    r.ImGui_SameLine(ctx)
    local save_col = dirty[active_tab] and 0xAA6600FF or 0x555555FF
    local save_hov = dirty[active_tab] and 0xCC8800FF or 0x666666FF
    local save_act = dirty[active_tab] and 0x884400FF or 0x444444FF
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        save_col)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), save_hov)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(),  save_act)
    if r.ImGui_Button(ctx, "  Save  ") and dirty[active_tab] then
      save_buf(active_tab)
    end
    r.ImGui_PopStyleColor(ctx, 3)

    r.ImGui_SameLine(ctx)
    local watching = ext_watch[active_tab] ~= nil
    local ext_col  = watching and 0x1A7A3AFF or 0x1E5080FF
    local ext_hov  = watching and 0x2AAD54FF or 0x2E72B0FF
    local ext_act  = watching and 0x0F5228FF or 0x0F365AFF
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        ext_col)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), ext_hov)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(),  ext_act)
    local ext_lbl = watching and "  * Live  " or "  Open in Editor  "
    if r.ImGui_Button(ctx, ext_lbl) then
      if watching then
        ext_watch[active_tab] = nil     -- stop watching
      else
        open_in_ext_editor(active_tab)  -- write file + launch app
      end
    end
    r.ImGui_PopStyleColor(ctx, 3)

    if dirty[active_tab] then
      r.ImGui_SameLine(ctx)
      r.ImGui_TextDisabled(ctx, "unsaved changes")
    end

    r.ImGui_Spacing(ctx)

    -- ---- Locked-mode banner (unsaved project: Global notes only) ----
    if not project_ready then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFCC44FF)
      r.ImGui_TextWrapped(ctx,
        "Global notes only \u{2014} " .. (why_locked or "project is unsaved.") ..
        "  Save the project with its own folder to unlock the " ..
        "Project / Track / Item / FX tabs.")
      r.ImGui_PopStyleColor(ctx, 1)
      r.ImGui_Spacing(ctx)
    end

    -- ---- Tab bar ----
    if r.ImGui_BeginTabBar(ctx, "##maintabs") then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TabSelected(), 0xFFFFFFFF)
      for i, name in ipairs(TAB_NAMES) do
        local lbl       = name .. "##ti" .. i
        local locked    = (not project_ready) and (i ~= TAB.GLOBAL)
        local tab_flags = dirty[i] and r.ImGui_TabItemFlags_UnsavedDocument() or 0

        if request_tab == i then
          tab_flags = tab_flags | r.ImGui_TabItemFlags_SetSelected()
        end

        local is_active = (i == active_tab)
        if is_active then
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x000000FF)
        end

        if locked then r.ImGui_BeginDisabled(ctx, true) end
        if r.ImGui_BeginTabItem(ctx, lbl, nil, tab_flags) then
          if is_active then r.ImGui_PopStyleColor(ctx, 1) end
          if request_tab == i then request_tab = nil end

          -- Double-click on Track / Item / FX tab → force the list view for
          -- that level without touching cur_* (sync_selections keeps running).
          if i >= TAB.TRACK
             and r.ImGui_IsItemHovered(ctx)
             and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
            if dirty[i] then save_buf(i) end
            editing_tab   = nil
            force_list[i] = true
          end

          if active_tab ~= i then
            if dirty[active_tab] then save_buf(active_tab) end
            active_tab = i
            load_buf(i)
          end

          if     i == TAB.GLOBAL   then draw_global(ctx)
          elseif i == TAB.PROJECT  then draw_project(ctx)
          elseif i == TAB.TRACK    then draw_track(ctx)
          elseif i == TAB.ITEM     then draw_item(ctx)
          elseif i == TAB.FX       then draw_fx(ctx)
          end

          r.ImGui_EndTabItem(ctx)
        elseif is_active then
          r.ImGui_PopStyleColor(ctx, 1)
        end
        if locked then r.ImGui_EndDisabled(ctx) end
      end
      r.ImGui_PopStyleColor(ctx, 1)
      r.ImGui_EndTabBar(ctx)
    end

    -- ---- About popup ----
    if show_about then
      r.ImGui_OpenPopup(ctx, "About Stomata Notes")
      show_about = false
    end
    if r.ImGui_BeginPopupModal(ctx, "About Stomata Notes", nil,
                               r.ImGui_WindowFlags_AlwaysAutoResize()) then
      r.ImGui_Text(ctx, "Stomata Notes")
      r.ImGui_Text(ctx, "Version " .. SCRIPT_VERSION)
      r.ImGui_Spacing(ctx)
      r.ImGui_Text(ctx, SCRIPT_URL)
      r.ImGui_Spacing(ctx)
      -- CF_ShellExecute (SWS extension) opens the URL in the default browser when
      -- available; otherwise the URL above can be copied manually.
      if r.ImGui_Button(ctx, "Visit Website") then
        if r.CF_ShellExecute then
          r.CF_ShellExecute(SCRIPT_URL)
        else
          r.ImGui_SetClipboardText(ctx, SCRIPT_URL)
          r.ShowMessageBox(
            "SWS extension not found.\nThe link has been copied to your clipboard:\n\n" ..
            SCRIPT_URL, SCRIPT_NAME, 0)
        end
      end
      r.ImGui_SameLine(ctx)
      if r.ImGui_Button(ctx, "Copy Link") then
        r.ImGui_SetClipboardText(ctx, SCRIPT_URL)
      end
      r.ImGui_SameLine(ctx)
      if r.ImGui_Button(ctx, "Close") then
        r.ImGui_CloseCurrentPopup(ctx)
      end
      r.ImGui_EndPopup(ctx)
    end

    r.ImGui_End(ctx)
  end

  if win_open then
    r.defer(frame)
  else
    save_all_dirty()
  end
end

-- ============================================================
-- CLEANUP
-- ============================================================

local function on_exit()
  save_all_dirty()
  -- Clean up any sentinel files we spawned so they don't confuse a future run.
  for _, w in pairs(ext_watch) do
    if w.sentinel then os.remove(w.sentinel) end
  end
end

-- ============================================================
-- PRECONDITIONS
--   The script writes .txt sidecar files alongside the project (see
--   get_project_dir / write_note_file).  If the project is untitled it has no
--   folder, so get_project_dir() falls back to Reaper's resource path and the
--   sidecars would be created as orphaned "unnamed_*.txt" files that collide
--   across sessions and never migrate.  Rather than refuse to run, we run in a
--   reduced "Global only" mode: the Global note (which lives in the resource
--   path by design and is project-independent) stays available, while the
--   project-scoped tabs are locked until the project has BOTH a name and a
--   folder (i.e. it has been saved).
-- ============================================================

-- Returns: ready (bool), why (string|nil) describing the missing precondition.
local function project_is_ready()
  local _, proj_file = r.EnumProjects(-1, "")
  local has_folder   = proj_file ~= nil and proj_file ~= ""
  local pname        = r.GetProjectName(0, "")
  local has_name     = pname ~= nil and pname ~= ""

  if has_folder and has_name then return true, nil end

  local why
  if not has_name and not has_folder then
    why = "This project is untitled and has no project folder."
  elseif not has_name then
    why = "This project is untitled."
  else
    why = "This project has no defined project folder."
  end
  return false, why
end

-- ============================================================
-- INIT
-- ============================================================

local function init()
  if not r.ImGui_CreateContext then
    r.ShowMessageBox(
      "ReaImGui extension not found.\n\n" ..
      "Install via: Extensions > ReaPack > Browse packages > search 'ReaImGui'",
      SCRIPT_NAME, 0)
    return
  end

  ctx = r.ImGui_CreateContext(SCRIPT_NAME)

  -- Evaluate the save state up front.  If the project isn't ready we open on
  -- the Global tab (the only one usable) and advise the user once.
  local ready, why = project_is_ready()
  project_ready = ready

  if ready then
    active_tab = determine_initial_tab()
  else
    active_tab     = TAB.GLOBAL
    warned_unsaved = true
    r.ShowMessageBox(
      why .. "\n\n" ..
      "Only the Global note is available right now.  The Project, Track,\n" ..
      "Item and FX tabs are locked to avoid creating orphaned note files\n" ..
      "in Reaper's resource folder.\n\n" ..
      "To unlock them:\n" ..
      "  1. Save the project (File > Save Project As...) to give it a name.\n" ..
      "  2. Enable \"Create subdirectory for project\" so it has its own folder.\n\n" ..
      "The tabs unlock automatically once the project is saved.",
      SCRIPT_NAME, 0)
  end
  request_tab = active_tab

  load_buf(TAB.GLOBAL)
  load_buf(TAB.PROJECT)
  load_buf(TAB.TRACK)
  load_buf(TAB.ITEM)
  load_buf(TAB.FX)

  r.atexit(on_exit)
  r.defer(frame)
end

init()