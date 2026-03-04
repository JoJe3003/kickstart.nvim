-- SourcePawn LSP and Filetype Configuration

-- Register .sp and .inc files as sourcepawn filetype
vim.filetype.add {
  extension = {
    sp = 'sourcepawn',
    inc = 'sourcepawn',
  },
}

-- Configure sourcepawn-studio LSP
vim.api.nvim_create_autocmd('User', {
  pattern = 'VeryLazy',
  callback = function()
    local lspconfig_available, lspconfig = pcall(require, 'lspconfig')
    if not lspconfig_available then return end

    -- Check if sourcepawn-studio exists
    if vim.fn.executable 'sourcepawn-studio' ~= 1 then
      vim.notify('sourcepawn-studio not found in PATH', vim.log.levels.WARN)
      return
    end

    -- Get capabilities from blink.cmp
    local capabilities = vim.lsp.protocol.make_client_capabilities()
    local has_blink, blink = pcall(require, 'blink.cmp')
    if has_blink then
      capabilities = blink.get_lsp_capabilities(capabilities)
    end

    -- Add sourcepawn-studio as a custom LSP server
    local configs = require 'lspconfig.configs'
    if not configs.sourcepawn_studio then
      configs.sourcepawn_studio = {
        default_config = {
          cmd = { 'sourcepawn-studio' },
          filetypes = { 'sourcepawn' },
          root_dir = function(fname)
            return lspconfig.util.find_git_ancestor(fname) or vim.fn.getcwd()
          end,
          settings = {
            sourcepawn = {
              includesDirectories = {},
            },
          },
          on_new_config = function(config, root_dir)
            -- Look for common SourcePawn include directories
            local include_paths = {}
            
            -- Check for scripting/include (most common)
            local scripting_include = root_dir .. '/scripting/include'
            if vim.fn.isdirectory(scripting_include) == 1 then
              table.insert(include_paths, scripting_include)
            end
            
            -- Check for addons/sourcemod/scripting/include (full sourcemod structure)
            local sm_include = root_dir .. '/addons/sourcemod/scripting/include'
            if vim.fn.isdirectory(sm_include) == 1 then
              table.insert(include_paths, sm_include)
            end
            
            -- Check for include/ in root
            local root_include = root_dir .. '/include'
            if vim.fn.isdirectory(root_include) == 1 then
              table.insert(include_paths, root_include)
            end
            
            -- Set both init_options and settings
            config.init_options = {
              includesDirectories = include_paths,
            }
            config.settings = {
              sourcepawn = {
                includesDirectories = include_paths,
              },
            }
          end,
        },
      }
    end

    -- Setup the LSP using lspconfig
    lspconfig.sourcepawn_studio.setup {
      capabilities = capabilities,
    }
  end,
})
