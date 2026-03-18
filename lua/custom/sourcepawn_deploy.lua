-- SourcePawn Compile & Deploy Module
-- Cross-platform (macOS / Windows) using vim.system, vim.fs, vim.uv
--
-- ── Keymaps (active in .sp buffers only) ───────────────────────────────────
--
--   <leader>cc   Compile current .sp → plugins/<name>.smx
--   <leader>cu   Upload current plugin's .smx to remote server
--   <leader>cU   Upload ALL .smx files + extra_upload_paths directories
--   <leader>ca   Compile + upload current .smx (one keystroke deploy)
--   <leader>cC   Compile ALL .sp files in scripting/ (and subfolders)
--   <leader>cA   Compile ALL .sp files, then upload all .smx files
--   <leader>cl   Toggle the [SourcePawn Log] window open/closed
--   <leader>ci   Show deploy info (root, spcomp, server, includes, reload state)
--   <leader>tsr  Toggle auto-reload: when ON, uploads will also send
--                "sm plugins reload <name>" to the remote tmux session
--   <leader>tsw  Toggle compile-on-save: when ON, auto-compiles on every :w
--
-- ── User commands ───────────────────────────────────────────────────────────
--
--   :SPCompile          Compile current .sp file
--   :SPUpload           Upload current plugin's .smx
--   :SPUploadAll        Upload all deployable files
--   :SPDeploy           Compile + upload current .smx
--   :SPCompileAll       Compile all .sp files in scripting/
--   :SPDeployAll        Compile all + upload all .smx
--   :SPInfo             Show deploy info
--   :SPToggleReload     Toggle auto-reload
--   :SPToggleCompile    Toggle compile-on-save
--   :SPClearCache       Clear per-project config cache
--
-- ── How it works ───────────────────────────────────────────────────────────
--
-- Project root detection:
--   Walks upward from the current .sp file looking for a directory named
--   "sourcemod/" that contains a "scripting/" subdirectory.
--
-- Compiler resolution (in order):
--   1. <sourcemod_root>/scripting/spcomp  (project-local, preferred)
--   2. M.cfg.spcomp or .spdeploy.json "spcomp" field
--   3. "spcomp" in PATH (fallback)
--
-- Include paths:
--   Automatically passes -i<root>/scripting/include to spcomp if that
--   directory exists. This is where sourcemod.inc and friends live.
--
-- Upload:
--   Uses ssh + scp (no rsync dependency). Creates remote directories
--   first via ssh mkdir -p, then uploads each file individually via scp.
--
--   <leader>cu uploads only the current plugin's .smx.
--   <leader>cU uploads ALL .smx files in plugins/ (including subfolders),
--   plus any directories listed in "extra_upload_paths".
--
--   By default, extra_upload_paths is empty (only .smx files are uploaded).
--   Add directories to upload via .spdeploy.json:
--     { "extra_upload_paths": ["translations", "gamedata", "configs"] }
--
--   The "exclude" list filters out files matching Lua patterns.
--   Never uploads: scripting/**, *.sp, .git/**, README.md (by default)
--
-- Remote reload:
--   When auto-reload is ON (<leader>tsr to toggle), after a successful
--   upload it runs: ssh <host> "tmux send-keys -t <session> 'sm plugins reload <name>' Enter"
--   Requires "tmux_session" to be set in M.cfg or .spdeploy.json.
--
-- Per-project config:
--   Drop a .spdeploy.json in or above your sourcemod/ root (e.g. repo root).
--   The search walks upward and stops at the first .git boundary.
--   See the example below near the get_config() function.
--   After editing .spdeploy.json, restart Neovim or run:
--     :lua require('custom.sourcepawn_deploy').clear_config_cache()
--
-- ── Prerequisites ──────────────────────────────────────────────────────────
--
--   spcomp   SourcePawn compiler (in PATH or in project scripting/ dir)
--   ssh      For remote directory creation and reload commands
--   scp      For file uploads
--   SSH key-based auth to your server (no password prompts)
--
-- ── Files ──────────────────────────────────────────────────────────────────
--
--   lua/custom/sourcepawn_deploy.lua   This module (compile/upload/reload)
--   lua/custom/sourcepawn.lua          Filetype, LSP, and keymap wiring
--

local M = {}

-- ── Default config (overridden per-project by .spdeploy.json) ──────────────

---@class SourcePawnDeployConfig
M.cfg = {
  spcomp = 'spcomp', -- auto-detects <root>/scripting/spcomp if present
  ssh_host = 'dzine',
  remote_base = '~/Steam/css/cstrike/addons/sourcemod',
  -- To find tmux targets, run on server:
  --   tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{window_name} #{pane_current_command}'
  tmux_session = '', -- remote tmux session name for plugin reload (e.g. "css")
  tmux_window = '0', -- remote tmux window index (default: first window)
  tmux_pane = '1', -- remote tmux pane index within window (default: second pane)

  plugins_dir = 'plugins', -- output dir for compiled .smx (relative to sourcemod root, e.g. "plugins/custom")
  extra_include_paths = {}, -- additional -i paths for spcomp (absolute paths, e.g. "C:/sourcemod/scripting/include")
  extra_upload_paths = {}, -- add dirs here or in .spdeploy.json (e.g. "translations", "gamedata", "configs")

  exclude = {
    '^scripting/',
    '%.sp$',
    '^%.git/',
    '^README%.md$',
  },
}

-- ── Runtime state ──────────────────────────────────────────────────────────
-- These are session-only (reset on Neovim restart).

M._log_buf = nil
M._log_min_height = 6 -- minimum log window height in lines
M._log_max_ratio = 0.4 -- max log height as fraction of editor (0.4 = 40%)
M._auto_reload = false -- toggle with <leader>tsr; sends reload after upload
M._compile_on_save = false -- toggle with <leader>tsw; compiles on every :w
M._project_cfg_cache = {} -- root path -> merged config (cleared by clear_config_cache())

-- ── Per-project config (.spdeploy.json) ────────────────────────────────────
-- Place in or above your sourcemod/ root (e.g. repo root). All fields optional.
--
-- Example .spdeploy.json:
-- {
--   "spcomp": "spcomp",
--   "ssh_host": "myserver",
--   "remote_base": "/home/user/server/addons/sourcemod",
--   "tmux_session": "css",
--   "tmux_window": "0",
--   "tmux_pane": "1",
--   "plugins_dir": "plugins/custom",
--   "extra_include_paths": ["C:/path/to/other/sourcemod/scripting/include"],
--   "extra_upload_paths": ["translations", "gamedata", "configs"],
--   "exclude": ["^scripting/", "\\.sp$", "^\\.git/", "^README\\.md$"]
-- }
--
-- extra_upload_paths: directories to include in <leader>cU / :SPUploadAll
--   Default is empty (only plugins/*.smx). Add dirs you want uploaded:
--   "translations" -> uploads sourcemod/translations/**
--   "gamedata"     -> uploads sourcemod/gamedata/**
--   "configs"      -> uploads sourcemod/configs/**
--
-- exclude: Lua patterns matched against relative paths (from sourcemod root)
--   Files matching ANY pattern are skipped during upload.

--- Find .spdeploy.json by walking upward from dir, stopping at .git boundary.
---@param start_dir string
---@return string|nil path to .spdeploy.json
local function find_spdeploy_json(start_dir)
  local dir = start_dir
  while dir do
    local candidate = dir .. '/.spdeploy.json'
    if (vim.uv or vim.loop).fs_stat(candidate) then return candidate end
    -- Stop at git root (don't search above the repo)
    if (vim.uv or vim.loop).fs_stat(dir .. '/.git') then break end
    local parent = vim.fs.dirname(dir)
    if parent == dir then break end
    dir = parent
  end
  return nil
end

--- Load and cache per-project config. Falls back to M.cfg for missing fields.
--- Searches for .spdeploy.json in the sourcemod root and upward to the repo root.
---@param root string sourcemod root
---@return SourcePawnDeployConfig
function M.get_config(root)
  if M._project_cfg_cache[root] then return M._project_cfg_cache[root] end

  local merged = vim.deepcopy(M.cfg)
  local config_path = find_spdeploy_json(root)
  if config_path then
    local f = io.open(config_path, 'r')
    if f then
      local content = f:read '*a'
      f:close()
      local ok, project = pcall(vim.json.decode, content)
      if ok and type(project) == 'table' then
        merged = vim.tbl_deep_extend('force', merged, project)
      else
        vim.notify('.spdeploy.json: invalid JSON', vim.log.levels.WARN)
      end
    end
  end

  M._project_cfg_cache[root] = merged
  return merged
end

--- Clear the config cache (useful after editing .spdeploy.json).
function M.clear_config_cache() M._project_cfg_cache = {} end

-- ── SourceMod root detection ───────────────────────────────────────────────

---@param start_path string
---@return string|nil
function M.find_sourcemod_root(start_path)
  local dir = vim.fs.dirname(start_path)
  while dir do
    if vim.fn.fnamemodify(dir, ':t') == 'sourcemod' and (vim.uv or vim.loop).fs_stat(dir .. '/scripting') then return dir end
    local parent = vim.fs.dirname(dir)
    if parent == dir then break end
    dir = parent
  end
  return nil
end

-- ── Exclude / collect helpers ──────────────────────────────────────────────

---@param rel_path string
---@param cfg SourcePawnDeployConfig
---@return boolean
function M.is_excluded(rel_path, cfg)
  for _, pattern in ipairs(cfg.exclude) do
    if rel_path:find(pattern) then return true end
  end
  return false
end

---@param base_dir string
---@param sub string
---@param cfg SourcePawnDeployConfig
---@return string[]
function M.collect_files(base_dir, sub, cfg)
  local results = {}
  local full = base_dir .. '/' .. sub
  local stat = (vim.uv or vim.loop).fs_stat(full)
  if not stat then return results end

  if stat.type == 'file' then
    if not M.is_excluded(sub, cfg) then table.insert(results, sub) end
    return results
  end

  local function walk(dir_path, rel_prefix)
    local handle = (vim.uv or vim.loop).fs_scandir(dir_path)
    if not handle then return end
    while true do
      local name, typ = (vim.uv or vim.loop).fs_scandir_next(handle)
      if not name then break end
      local rel = rel_prefix .. '/' .. name
      local abs = dir_path .. '/' .. name
      if typ == 'directory' then
        walk(abs, rel)
      else
        if not M.is_excluded(rel, cfg) then table.insert(results, rel) end
      end
    end
  end

  walk(full, sub)
  return results
end

-- ── Timestamp helper ───────────────────────────────────────────────────────

function M.timestamp() return os.date '%H:%M:%S' end

--- Format elapsed seconds as a human-readable string.
---@param start number vim.uv.hrtime() value (nanoseconds)
---@return string e.g. "0.8s", "1.2s"
function M.elapsed(start) return string.format('%.1fs', (vim.uv.hrtime() - start) / 1e9) end

-- ── Log buffer management ──────────────────────────────────────────────────

--- Open log split without stealing focus.
---@return integer bufnr
function M.open_log()
  local prev_win = vim.api.nvim_get_current_win()

  if M._log_buf and vim.api.nvim_buf_is_valid(M._log_buf) then
    local wins = vim.fn.win_findbuf(M._log_buf)
    if #wins == 0 then
      vim.cmd 'botright 12split'
      vim.api.nvim_win_set_buf(0, M._log_buf)
    end
  else
    vim.cmd 'botright 12new'
    M._log_buf = vim.api.nvim_get_current_buf()
    vim.bo[M._log_buf].buftype = 'nofile'
    vim.bo[M._log_buf].bufhidden = 'hide'
    vim.bo[M._log_buf].swapfile = false
    vim.api.nvim_buf_set_name(M._log_buf, '[SourcePawn Log]')
  end

  vim.api.nvim_set_current_win(prev_win)
  return M._log_buf
end

--- Toggle log window visibility.
function M.toggle_log()
  if M._log_buf and vim.api.nvim_buf_is_valid(M._log_buf) then
    local wins = vim.fn.win_findbuf(M._log_buf)
    if #wins > 0 then
      for _, w in ipairs(wins) do
        vim.api.nvim_win_close(w, false)
      end
      return
    end
  end
  M.open_log()
end

function M.resize_log()
  local buf = M._log_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local line_count = vim.api.nvim_buf_line_count(buf)
  local max_height = math.floor(vim.o.lines * M._log_max_ratio)
  local height = math.max(M._log_min_height, math.min(line_count, max_height))
  local wins = vim.fn.win_findbuf(buf)
  for _, w in ipairs(wins) do
    vim.api.nvim_win_set_height(w, height)
  end
end

---@param lines string[]
function M.log_write(lines)
  local buf = M.open_log()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  M.resize_log()
  local wins = vim.fn.win_findbuf(buf)
  for _, w in ipairs(wins) do
    vim.api.nvim_win_set_cursor(w, { #lines, 0 })
  end
  vim.cmd 'redraw'
end

---@param lines string[]
function M.log_append(lines)
  local buf = M.open_log()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  vim.bo[buf].modifiable = false
  M.resize_log()
  local total = vim.api.nvim_buf_line_count(buf)
  local wins = vim.fn.win_findbuf(buf)
  for _, w in ipairs(wins) do
    vim.api.nvim_win_set_cursor(w, { total, 0 })
  end
  vim.cmd 'redraw'
end

-- ── Path helper ─────────────────────────────────────────────────────────────

local _is_win = vim.fn.has 'win32' == 1

--- Normalize a path to use the OS-native separator (backslash on Windows).
---@param path string
---@return string
local function native_path(path)
  if _is_win then return (path:gsub('/', '\\')) end
  return path
end

-- ── Shell helper ───────────────────────────────────────────────────────────

---@param cmd string[]
---@param opts? { cwd?: string }
---@return { code: integer, stdout: string, stderr: string }
function M.run(cmd, opts)
  local result = vim.system(cmd, { text = true, cwd = opts and opts.cwd }):wait()
  return { code = result.code, stdout = result.stdout or '', stderr = result.stderr or '' }
end

-- ── SSH display name ──────────────────────────────────────────────────────

M._ssh_display_cache = {} -- host alias -> "user@hostname"

--- Resolve an SSH host alias to "user@hostname" for display purposes.
--- Uses `ssh -G <host>` to read the resolved config. Cached per session.
---@param host string SSH host alias (e.g. "dzine")
---@return string display name (e.g. "pudding@prov.one")
function M.ssh_display_name(host)
  if M._ssh_display_cache[host] then return M._ssh_display_cache[host] end

  local res = M.run { 'ssh', '-G', host }
  if res.code ~= 0 then
    M._ssh_display_cache[host] = host
    return host
  end

  local user, hostname
  for line in res.stdout:gmatch '[^\r\n]+' do
    local key, val = line:match '^(%S+)%s+(.+)$'
    if key == 'user' then user = val end
    if key == 'hostname' then hostname = val end
  end

  local display = (user and hostname) and (user .. '@' .. hostname) or host
  M._ssh_display_cache[host] = display
  return display
end

-- ── Compile ────────────────────────────────────────────────────────────────

---@param callback? fun(ok: boolean, smx_path: string|nil, root: string|nil)
function M.compile(callback)
  local bufname = vim.api.nvim_buf_get_name(0)
  if not bufname:match '%.sp$' then
    vim.notify('Current buffer is not a .sp file', vim.log.levels.WARN)
    if callback then callback(false) end
    return
  end

  vim.cmd 'silent update'

  local root = M.find_sourcemod_root(bufname)
  if not root then
    vim.notify('Could not find sourcemod/ root', vim.log.levels.ERROR)
    if callback then callback(false) end
    return
  end

  local cfg = M.get_config(root)
  local basename = vim.fn.fnamemodify(bufname, ':t:r')
  local plugins_dir = root .. '/' .. cfg.plugins_dir
  vim.fn.mkdir(plugins_dir, 'p')
  local output = plugins_dir .. '/' .. basename .. '.smx'

  -- Resolve spcomp
  local spcomp = cfg.spcomp
  local local_spcomp = root .. '/scripting/spcomp'
  local local_spcomp_exe = root .. '/scripting/spcomp.exe'
  if (vim.uv or vim.loop).fs_stat(local_spcomp) then
    spcomp = local_spcomp
  elseif (vim.uv or vim.loop).fs_stat(local_spcomp_exe) then
    spcomp = local_spcomp_exe
  end

  -- Build command with include paths
  local cmd = { spcomp, bufname, '-o', native_path(output) }
  local include_dir = root .. '/scripting/include'
  if (vim.uv or vim.loop).fs_stat(include_dir) then table.insert(cmd, '-i' .. native_path(include_dir)) end
  for _, extra in ipairs(cfg.extra_include_paths) do
    table.insert(cmd, '-i' .. native_path(extra))
  end

  local t0 = vim.uv.hrtime()
  local result = M.run(cmd)
  local full_output = result.stdout .. result.stderr

  local log_lines = { '── [' .. M.timestamp() .. '] Compile: ' .. basename .. '.sp ──', '' }
  for line in full_output:gmatch '[^\r\n]+' do
    table.insert(log_lines, line)
  end
  table.insert(log_lines, '')

  if result.code == 0 then
    table.insert(log_lines, '✓ Compiled ' .. basename .. '.smx in ' .. M.elapsed(t0))
    M.log_write(log_lines)
    if callback then callback(true, output, root) end
  else
    table.insert(log_lines, '✗ Compile failed (exit ' .. result.code .. ')')
    M.log_write(log_lines)
    if callback then callback(false) end
  end
end

-- ── Upload ─────────────────────────────────────────────────────────────────

---@param root string
---@param files string[]
---@param plugin_name? string basename of the plugin (for reload)
function M.upload_files(root, files, plugin_name)
  if #files == 0 then
    vim.notify('No files to upload', vim.log.levels.WARN)
    return
  end

  local cfg = M.get_config(root)

  -- Create remote directories
  local remote_dirs = {}
  for _, rel in ipairs(files) do
    local dir = vim.fn.fnamemodify(rel, ':h')
    if dir ~= '.' then remote_dirs[cfg.remote_base .. '/' .. dir] = true end
  end

  if next(remote_dirs) then
    local mkdir_args = {}
    for d, _ in pairs(remote_dirs) do
      table.insert(mkdir_args, d)
    end
    local mkdir_cmd = 'mkdir -p ' .. table.concat(mkdir_args, ' ')
    local res = M.run { 'ssh', cfg.ssh_host, mkdir_cmd }
    if res.code ~= 0 then
      M.log_append { '  ✗ Connection failed: ' .. res.stderr:gsub('[\r\n]+$', ''), '' }
      return
    end
    M.log_append { '  ✓ Connected to ' .. M.ssh_display_name(cfg.ssh_host), '' }
  end

  -- Upload files (logged live, one at a time)
  local t0 = vim.uv.hrtime()
  M.log_append { '── [' .. M.timestamp() .. '] Upload (' .. #files .. ' file(s)) ──', '' }
  local failed = 0
  for i, rel in ipairs(files) do
    local local_path = root .. '/' .. rel
    local remote_path = cfg.ssh_host .. ':' .. cfg.remote_base .. '/' .. rel
    local res = M.run { 'scp', local_path, remote_path }
    if res.code ~= 0 then
      M.log_append { string.format('  [%d/%d] ✗ %s', i, #files, rel) }
      if res.stderr ~= '' then M.log_append { '    ' .. res.stderr:gsub('[\r\n]+$', '') } end
      failed = failed + 1
    else
      M.log_append { string.format('  [%d/%d] ✓ %s', i, #files, rel) }
    end
  end

  if failed == 0 then
    M.log_append { '', string.format('✓ Uploaded %d file(s) in %s', #files, M.elapsed(t0)) }
  else
    M.log_append { '', string.format('✗ Upload done with %d failure(s) in %s', failed, M.elapsed(t0)) }
  end

  -- Remote reload if enabled
  if failed == 0 and M._auto_reload and plugin_name then
    M.reload_plugin(root, plugin_name)
  end
end

--- Upload only the current buffer's compiled .smx.
function M.upload()
  local bufname = vim.api.nvim_buf_get_name(0)
  if not bufname:match '%.sp$' then
    vim.notify('Current buffer is not a .sp file', vim.log.levels.WARN)
    return
  end

  local root = M.find_sourcemod_root(bufname)
  if not root then
    vim.notify('Could not find sourcemod/ root', vim.log.levels.ERROR)
    return
  end

  local cfg = M.get_config(root)
  local basename = vim.fn.fnamemodify(bufname, ':t:r')
  local smx_rel = cfg.plugins_dir .. '/' .. basename .. '.smx'
  local smx_abs = root .. '/' .. smx_rel

  if not (vim.uv or vim.loop).fs_stat(smx_abs) then
    vim.notify(basename .. '.smx not found — compile first', vim.log.levels.WARN)
    return
  end

  -- Start a fresh log when uploading standalone (no prior compile log)
  M.log_write { '── [' .. M.timestamp() .. '] Upload: ' .. basename .. '.smx ──' }
  M.upload_files(root, { smx_rel }, basename)
end

--- Upload all deployable files.
function M.upload_all()
  local bufname = vim.api.nvim_buf_get_name(0)
  local root = M.find_sourcemod_root(bufname)
  if not root then
    vim.notify('Could not find sourcemod/ root', vim.log.levels.ERROR)
    return
  end

  M.log_write { '── [' .. M.timestamp() .. '] Upload All ──' }

  local cfg = M.get_config(root)
  local files = {}

  local plugin_files = M.collect_files(root, cfg.plugins_dir, cfg)
  for _, f in ipairs(plugin_files) do
    if f:match '%.smx$' then table.insert(files, f) end
  end

  for _, sub in ipairs(cfg.extra_upload_paths) do
    vim.list_extend(files, M.collect_files(root, sub, cfg))
  end

  -- Deduplicate
  local seen = {}
  local unique = {}
  for _, f in ipairs(files) do
    if not seen[f] then
      seen[f] = true
      table.insert(unique, f)
    end
  end

  M.upload_files(root, unique)
end

-- ── Compile + Upload ───────────────────────────────────────────────────────

function M.compile_and_upload()
  local basename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t:r')
  M.compile(function(ok, _, root)
    if not ok then return end
    local cfg = M.get_config(root)
    M.upload_files(root, { cfg.plugins_dir .. '/' .. basename .. '.smx' }, basename)
  end)
end

-- ── Compile All ────────────────────────────────────────────────────────────

--- Compile a single .sp file by absolute path. Returns (ok, spcomp_version).
--- In compact mode, logs one line per file; full output only on failure.
---@param sp_path string absolute path to .sp file
---@param root string sourcemod root
---@param cfg SourcePawnDeployConfig
---@param index integer 1-based index in the batch
---@param total integer total files in the batch
---@return boolean ok
---@return string|nil spcomp_version (from first line of output, if present)
function M.compile_file(sp_path, root, cfg, index, total)
  local basename = vim.fn.fnamemodify(sp_path, ':t:r')
  local plugins_dir = root .. '/' .. cfg.plugins_dir
  vim.fn.mkdir(plugins_dir, 'p')
  local output = plugins_dir .. '/' .. basename .. '.smx'

  local spcomp = cfg.spcomp
  local local_spcomp = root .. '/scripting/spcomp'
  local local_spcomp_exe = root .. '/scripting/spcomp.exe'
  if (vim.uv or vim.loop).fs_stat(local_spcomp) then
    spcomp = local_spcomp
  elseif (vim.uv or vim.loop).fs_stat(local_spcomp_exe) then
    spcomp = local_spcomp_exe
  end

  local cmd = { spcomp, sp_path, '-o', native_path(output) }
  local include_dir = root .. '/scripting/include'
  if (vim.uv or vim.loop).fs_stat(include_dir) then table.insert(cmd, '-i' .. native_path(include_dir)) end
  for _, extra in ipairs(cfg.extra_include_paths) do
    table.insert(cmd, '-i' .. native_path(extra))
  end

  local result = M.run(cmd)
  local full_output = result.stdout .. result.stderr

  -- Extract spcomp version from first non-empty line
  local version = full_output:match '^([^\r\n]+)'

  if result.code == 0 then
    M.log_append { string.format('  [%d/%d] ✓ %s.smx', index, total, basename) }
  else
    -- On failure, show the one-liner then dump full output indented
    M.log_append { string.format('  [%d/%d] ✗ %s.sp (exit %d)', index, total, basename, result.code) }
    for line in full_output:gmatch '[^\r\n]+' do
      M.log_append { '    ' .. line }
    end
  end

  return result.code == 0, version
end

--- Find all .sp files in scripting/ and subfolders.
---@param root string sourcemod root
---@return string[] absolute paths
function M.find_all_sp(root)
  local sp_files = {}
  local scripting_dir = root .. '/scripting'

  local function walk(dir_path)
    local handle = (vim.uv or vim.loop).fs_scandir(dir_path)
    if not handle then return end
    while true do
      local name, typ = (vim.uv or vim.loop).fs_scandir_next(handle)
      if not name then break end
      local abs = dir_path .. '/' .. name
      if typ == 'directory' and name ~= 'include' then
        walk(abs)
      elseif typ == 'file' and name:match '%.sp$' then
        table.insert(sp_files, abs)
      end
    end
  end

  walk(scripting_dir)
  table.sort(sp_files)
  return sp_files
end

--- Compile all .sp files in scripting/ and subfolders.
---@param callback? fun(all_ok: boolean, root: string)
function M.compile_all(callback)
  local bufname = vim.api.nvim_buf_get_name(0)
  local root = M.find_sourcemod_root(bufname)
  if not root then
    vim.notify('Could not find sourcemod/ root', vim.log.levels.ERROR)
    if callback then callback(false, '') end
    return
  end

  local cfg = M.get_config(root)
  local sp_files = M.find_all_sp(root)

  if #sp_files == 0 then
    vim.notify('No .sp files found in scripting/', vim.log.levels.WARN)
    if callback then callback(false, root) end
    return
  end

  local t0 = vim.uv.hrtime()
  M.log_write { '── [' .. M.timestamp() .. '] Compile All (' .. #sp_files .. ' file(s)) ──', '' }

  local succeeded, failed = 0, 0
  local version
  for i, sp in ipairs(sp_files) do
    local ok, ver = M.compile_file(sp, root, cfg, i, #sp_files)
    if ok then
      succeeded = succeeded + 1
    else
      failed = failed + 1
    end
    if i == 1 and ver then version = ver end
  end

  M.log_append { '' }
  if version then M.log_append { 'spcomp: ' .. version } end
  if failed == 0 then
    M.log_append { string.format('✓ Compiled %d file(s) in %s', succeeded, M.elapsed(t0)) }
  else
    M.log_append { string.format('✗ Compile All: %d succeeded, %d failed in %s', succeeded, failed, M.elapsed(t0)) }
  end

  if callback then callback(failed == 0, root) end
end

--- Compile all .sp files, then upload all .smx files + extra paths.
function M.compile_all_and_upload()
  M.compile_all(function(all_ok, root)
    if root == '' then return end
    -- Upload even if some failed — the ones that succeeded still have .smx files
    local cfg = M.get_config(root)
    local files = {}

    local plugin_files = M.collect_files(root, cfg.plugins_dir, cfg)
    for _, f in ipairs(plugin_files) do
      if f:match '%.smx$' then table.insert(files, f) end
    end

    for _, sub in ipairs(cfg.extra_upload_paths) do
      vim.list_extend(files, M.collect_files(root, sub, cfg))
    end

    -- Deduplicate
    local seen = {}
    local unique = {}
    for _, f in ipairs(files) do
      if not seen[f] then
        seen[f] = true
        table.insert(unique, f)
      end
    end

    M.upload_files(root, unique)
  end)
end

-- ── Remote reload via tmux ─────────────────────────────────────────────────

---@param root string
---@param plugin_name string
function M.reload_plugin(root, plugin_name)
  local cfg = M.get_config(root)

  if cfg.tmux_session == '' then
    M.log_append { '', '⚠ Reload skipped: tmux_session not set in config' }
    return
  end

  -- Derive reload name relative to plugins/ (e.g. "plugins/trikzclub" -> "trikzclub/chat")
  local reload_name = plugin_name
  local sub = cfg.plugins_dir:match '^plugins/(.+)$'
  if sub then reload_name = sub .. '/' .. plugin_name end

  local reload_cmd = 'sm plugins reload ' .. reload_name
  local res = M.run {
    'ssh',
    cfg.ssh_host,
    string.format("tmux send-keys -t %s:%s.%s '%s' Enter", cfg.tmux_session, cfg.tmux_window, cfg.tmux_pane, reload_cmd),
  }

  local reload_lines = { '', '── [' .. M.timestamp() .. '] Reload ──', '' }
  if res.code == 0 then
    table.insert(reload_lines, '✓ Sent: ' .. reload_cmd)
  else
    table.insert(reload_lines, '✗ Reload failed')
    if res.stderr ~= '' then table.insert(reload_lines, '  ' .. res.stderr:gsub('[\r\n]+$', '')) end
  end
  M.log_append(reload_lines)
end

--- Toggle auto-reload after upload.
function M.toggle_auto_reload()
  M._auto_reload = not M._auto_reload
  local state = M._auto_reload and 'ON' or 'OFF'
  vim.notify('SourceMod auto-reload: ' .. state, vim.log.levels.INFO)
end

--- Toggle compile-on-save for .sp files.
function M.toggle_compile_on_save()
  M._compile_on_save = not M._compile_on_save
  local state = M._compile_on_save and 'ON' or 'OFF'
  vim.notify('SourcePawn compile-on-save: ' .. state, vim.log.levels.INFO)
end

-- ── Status / Info ──────────────────────────────────────────────────────────

function M.show_info()
  local bufname = vim.api.nvim_buf_get_name(0)
  local root = M.find_sourcemod_root(bufname)

  local lines = { '── SourcePawn Deploy Info ──', '' }

  if not root then
    table.insert(lines, '✗ No sourcemod/ root detected')
    M.log_write(lines)
    return
  end

  local cfg = M.get_config(root)

  table.insert(lines, 'Root:        ' .. root)

  -- spcomp
  local spcomp = cfg.spcomp
  local local_spcomp = root .. '/scripting/spcomp'
  if (vim.uv or vim.loop).fs_stat(local_spcomp) then spcomp = local_spcomp .. ' (project-local)' end
  table.insert(lines, 'spcomp:      ' .. spcomp)

  -- Includes
  local include_dir = root .. '/scripting/include'
  local has_includes = (vim.uv or vim.loop).fs_stat(include_dir) and 'yes' or 'no'
  table.insert(lines, 'Includes:    ' .. include_dir .. ' (' .. has_includes .. ')')

  -- Server
  table.insert(lines, 'SSH host:    ' .. M.ssh_display_name(cfg.ssh_host))
  table.insert(lines, 'Remote:      ' .. cfg.remote_base)

  -- Tmux
  local tmux = cfg.tmux_session ~= '' and (cfg.tmux_session .. ':' .. cfg.tmux_window .. '.' .. cfg.tmux_pane) or '(not set)'
  table.insert(lines, 'Tmux:        ' .. tmux)

  -- Toggle states
  table.insert(lines, 'Auto-reload:     ' .. (M._auto_reload and 'ON' or 'OFF'))
  table.insert(lines, 'Compile-on-save: ' .. (M._compile_on_save and 'ON' or 'OFF'))

  -- Per-project config
  local cfg_path = find_spdeploy_json(root)
  local cfg_display = cfg_path and cfg_path or '(not found)'
  table.insert(lines, 'Project cfg: ' .. cfg_display)

  table.insert(lines, '')
  M.log_write(lines)
end

-- ── User commands ──────────────────────────────────────────────────────────

vim.api.nvim_create_user_command('SPCompile', function() M.compile() end, { desc = 'SourcePawn: Compile current .sp' })
vim.api.nvim_create_user_command('SPUpload', function() M.upload() end, { desc = 'SourcePawn: Upload current .smx' })
vim.api.nvim_create_user_command('SPUploadAll', function() M.upload_all() end, { desc = 'SourcePawn: Upload all deployable files' })
vim.api.nvim_create_user_command('SPDeploy', function() M.compile_and_upload() end, { desc = 'SourcePawn: Compile + upload' })
vim.api.nvim_create_user_command('SPCompileAll', function() M.compile_all() end, { desc = 'SourcePawn: Compile all .sp files' })
vim.api.nvim_create_user_command('SPDeployAll', function() M.compile_all_and_upload() end, { desc = 'SourcePawn: Compile all + upload all' })
vim.api.nvim_create_user_command('SPInfo', function() M.show_info() end, { desc = 'SourcePawn: Show deploy info' })
vim.api.nvim_create_user_command('SPToggleReload', function() M.toggle_auto_reload() end, { desc = 'SourcePawn: Toggle auto-reload' })
vim.api.nvim_create_user_command('SPToggleCompile', function() M.toggle_compile_on_save() end, { desc = 'SourcePawn: Toggle compile-on-save' })
vim.api.nvim_create_user_command('SPClearCache', function() M.clear_config_cache() end, { desc = 'SourcePawn: Clear project config cache' })

return M
