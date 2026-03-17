-- SourcePawn Symbol Search
-- Searches all functions, forwards, enums, etc. in include files

local M = {}

-- Find the include directory based on current file
local function find_include_dir()
  local root = vim.fn.getcwd()
  
  -- Try common locations
  local candidates = {
    root .. '/scripting/include',
    root .. '/addons/sourcemod/scripting/include',
    root .. '/include',
  }
  
  for _, dir in ipairs(candidates) do
    if vim.fn.isdirectory(dir) == 1 then
      return dir
    end
  end
  
  return nil
end

-- Parse include files and extract symbols
local function parse_include_files(include_dir)
  local symbols = {}
  
  -- Find all .inc files recursively
  local find_cmd = string.format('find "%s" -type f -name "*.inc"', include_dir)
  local files = vim.fn.systemlist(find_cmd)
  
  for _, file in ipairs(files) do
    local relative_file = file:gsub(include_dir .. '/', '')
    local lines = vim.fn.readfile(file)
    
    for line_num, line in ipairs(lines) do
      -- Match forwards
      local forward_match = line:match('^forward%s+[%w_]+%s+([%w_]+)%(')
      if forward_match then
        table.insert(symbols, {
          name = forward_match,
          type = 'forward',
          file = relative_file,
          line = line_num,
          full_line = line:gsub('^%s+', ''),
        })
      end
      
      -- Match stock functions
      local stock_match = line:match('^stock%s+[%w_]+%s+([%w_]+)%(')
      if stock_match then
        table.insert(symbols, {
          name = stock_match,
          type = 'stock',
          file = relative_file,
          line = line_num,
          full_line = line:gsub('^%s+', ''),
        })
      end
      
      -- Match native functions
      local native_match = line:match('^native%s+[%w_]+%s+([%w_]+)%(')
      if native_match then
        table.insert(symbols, {
          name = native_match,
          type = 'native',
          file = relative_file,
          line = line_num,
          full_line = line:gsub('^%s+', ''),
        })
      end
      
      -- Match enums
      local enum_match = line:match('^enum%s+([%w_]+)')
      if enum_match then
        table.insert(symbols, {
          name = enum_match,
          type = 'enum',
          file = relative_file,
          line = line_num,
          full_line = line:gsub('^%s+', ''),
        })
      end
      
      -- Match methodmap
      local methodmap_match = line:match('^methodmap%s+([%w_]+)')
      if methodmap_match then
        table.insert(symbols, {
          name = methodmap_match,
          type = 'methodmap',
          file = relative_file,
          line = line_num,
          full_line = line:gsub('^%s+', ''),
        })
      end
      
      -- Match public functions (in case we're searching .sp files too)
      local public_match = line:match('^public%s+[%w_]+%s+([%w_]+)%(')
      if public_match then
        table.insert(symbols, {
          name = public_match,
          type = 'public',
          file = relative_file,
          line = line_num,
          full_line = line:gsub('^%s+', ''),
        })
      end
    end
  end
  
  return symbols
end

-- Create Telescope picker
function M.search_symbols()
  local include_dir = find_include_dir()
  
  if not include_dir then
    vim.notify('Could not find include directory', vim.log.levels.ERROR)
    return
  end
  
  vim.notify('Indexing include files...', vim.log.levels.INFO)
  
  local symbols = parse_include_files(include_dir)
  
  if #symbols == 0 then
    vim.notify('No symbols found', vim.log.levels.WARN)
    return
  end
  
  local pickers = require 'telescope.pickers'
  local finders = require 'telescope.finders'
  local conf = require('telescope.config').values
  local actions = require 'telescope.actions'
  local action_state = require 'telescope.actions.state'
  
  pickers
    .new({}, {
      prompt_title = 'SourcePawn Symbols',
      finder = finders.new_table {
        results = symbols,
        entry_maker = function(entry)
          local full_path = include_dir .. '/' .. entry.file
          -- Extract just the filename from the path
          local filename = entry.file:match('([^/]+)$') or entry.file
          return {
            value = entry,
            display = string.format('[%s] %s  (%s)', entry.type, entry.name, filename),
            ordinal = entry.name .. ' ' .. entry.file .. ' ' .. entry.type,
            filename = full_path,
            lnum = entry.line,
            col = 1,
          }
        end,
      },
      sorter = conf.generic_sorter {},
      previewer = conf.grep_previewer({}),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          
          -- Open the file at the line
          vim.cmd('edit ' .. vim.fn.fnameescape(selection.filename))
          vim.api.nvim_win_set_cursor(0, { selection.lnum, 0 })
        end)
        return true
      end,
    })
    :find()
end

return M
