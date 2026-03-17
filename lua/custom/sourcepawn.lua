-- SourcePawn LSP, Filetype, and Deploy Configuration

local deploy = require 'custom.sourcepawn_deploy'

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
    if has_blink then capabilities = blink.get_lsp_capabilities(capabilities) end

    -- Add sourcepawn-studio as a custom LSP server
    local configs = require 'lspconfig.configs'
    if not configs.sourcepawn_studio then
      configs.sourcepawn_studio = {
        default_config = {
          cmd = { 'sourcepawn-studio' },
          filetypes = { 'sourcepawn' },
          root_dir = function(fname)
            -- Search upward for common project markers
            return vim.fs.root(fname, { '.git', 'scripting', 'gamedata', 'translations' }) or vim.fs.dirname(fname) or vim.fn.getcwd()
          end,
          on_new_config = function(config, root_dir)
            local include_paths = {}

            -- Check for local includes
            local local_scripting_include = root_dir .. '/scripting/include'
            local local_root_include = root_dir .. '/include'

            if vim.fn.isdirectory(local_scripting_include) == 1 then table.insert(include_paths, local_scripting_include) end
            if vim.fn.isdirectory(local_root_include) == 1 then table.insert(include_paths, local_root_include) end

            -- Set the standard config options
            config.init_options = {
              includeDirectories = include_paths,
              compiler = { path = 'spcomp' },
            }
            config.settings = {
              sourcepawn = {
                includeDirectories = include_paths,
                compiler = { path = 'spcomp' },
              },
            }

            -- THE FIX: Force Neovim to register include directories as workspace roots
            -- This prevents the 'FileSourceRootQuery' panic when jumping to .inc files
            config.workspace_folders = {
              {
                name = 'project_root',
                uri = vim.uri_from_fname(root_dir),
              },
            }

            for i, path in ipairs(include_paths) do
              table.insert(config.workspace_folders, {
                name = 'include_dir_' .. tostring(i),
                uri = vim.uri_from_fname(path),
              })
            end
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

-- SourcePawn compile & deploy keymaps (only active in .sp buffers)
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'sourcepawn',
  callback = function(ev)
    local opts = function(desc) return { buffer = ev.buf, desc = desc } end
    vim.keymap.set('n', '<leader>cc', deploy.compile, opts '[C]ompile current plugin')
    vim.keymap.set('n', '<leader>cu', deploy.upload, opts '[U]pload current .smx')
    vim.keymap.set('n', '<leader>cU', deploy.upload_all, opts '[U]pload all deployable files')
    vim.keymap.set('n', '<leader>ca', deploy.compile_and_upload, opts 'Compile + Upload [A]ll')
    vim.keymap.set('n', '<leader>cC', function() deploy.compile_all() end, opts '[C]ompile all .sp files')
    vim.keymap.set('n', '<leader>cA', deploy.compile_all_and_upload, opts 'Compile [A]ll + upload all')
    vim.keymap.set('n', '<leader>cl', deploy.toggle_log, opts 'Toggle [L]og window')
    vim.keymap.set('n', '<leader>ci', deploy.show_info, opts 'Show deploy [I]nfo')
    vim.keymap.set('n', '<leader>tsr', deploy.toggle_auto_reload, opts '[T]oggle [S]ourcemod [R]eload')
    vim.keymap.set('n', '<leader>tsw', deploy.toggle_compile_on_save, opts '[T]oggle compile-on-[S]ave [W]rite')
  end,
})

-- Compile-on-save autocmd (only fires when toggle is ON)
vim.api.nvim_create_autocmd('BufWritePost', {
  pattern = '*.sp',
  callback = function()
    if deploy._compile_on_save then deploy.compile() end
  end,
})
