local libmodal = require('libmodal')
local startFunc = 'libModalStart'
local exitFunc = 'libModalExit'
local prefix

local function generateFunc(layer)
  local start = function()
    if not layer:isActive() then
      layer:enter()
      vim.o.timeoutlen = 0
    end
  end
  local exit = function()
    layer:exit()
    vim.o.timeoutlen = 5000
  end
  return start, exit
end

local function ignoreList(keys, ignore)
  for index, key in pairs(keys) do
    for _, ikey in pairs(ignore) do
      if key == ikey then
        table.remove(keys, index)
      end
    end
  end
  return keys
end

local function generateEndKeymap(layer, func, ignore)
  local keys = {
    'a','b','c','d','e','f','g','h','i',
    'j','k','l','m','n','o','p','q','r',
    's','t','u','v','w','x','y','z',';',
    ':',',','/',''
  }
  if ignore then
    keys = ignoreList(keys, ignore)
  end
  for _, key in pairs(keys) do
    layer:map( 'n', key, ':lua ' .. func .. '()<CR>' .. key, {['noremap'] = true, ['silent']  = true})
  end
end

-- move diagnostics
local diagnosticLayer = libmodal.Layer.new({
  ['n'] = {
    ['['] = {
      ['rhs'] = ':DiagnosticPrevious<CR>',
      ['noremap'] = true,
      ['silent'] = true,
    },
    [']'] = {
      ['rhs'] = ':DiagnosticNext<CR>',
      ['noremap'] = true,
      ['silent'] = true,
    }
  }
})
prefix = 'Diag'
_G[startFunc..prefix], _G[exitFunc..prefix] = generateFunc(diagnosticLayer)
generateEndKeymap(diagnosticLayer, exitFunc..prefix)
vim.api.nvim_set_keymap('n', '[a', ':DiagnosticPrevious<CR>:lua ' .. startFunc .. prefix .. '()<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', ']a', ':DiagnosticNext<CR>:lua ' .. startFunc .. prefix .. '()<CR>', { noremap = true, silent = true })

-- block_move
local blockMoveLayer = libmodal.Layer.new({
  ['n'] = {
    [']'] = {
      ['rhs'] = ':call matchup#motion#jump_inside(0)<CR>',
      ['noremap'] = true,
      ['silent'] = true,
    },
    ['['] = {
      ['rhs'] = '<C-o>',
      ['noremap'] = true,
      ['silent'] = true,
    }
  }
})
prefix = 'Block'
_G[startFunc..prefix], _G[exitFunc..prefix] = generateFunc(blockMoveLayer)
generateEndKeymap(blockMoveLayer, exitFunc..prefix)
vim.api.nvim_set_keymap('n', '<M-]>',
  ':call matchup#motion#jump_inside(0)<CR>:lua ' .. startFunc .. prefix .. '()<CR>', { noremap = true, silent = true })

-- history_move
local hitoryMoveLayer = libmodal.Layer.new({
  ['n'] = {
    [';'] = {
      ['rhs'] = 'g;',
      ['noremap'] = true,
      ['silent'] = true,
    },
    [','] = {
      ['rhs'] = 'g,',
      ['noremap'] = true,
      ['silent'] = true,
    }
  }
})
prefix = 'Hitory'
_G[startFunc..prefix], _G[exitFunc..prefix] = generateFunc(hitoryMoveLayer)
generateEndKeymap(hitoryMoveLayer, exitFunc..prefix, {';', ','})
vim.api.nvim_set_keymap('n', 'g;', 'g;:lua ' .. startFunc .. prefix .. '()<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', 'g,', 'g,:lua ' .. startFunc .. prefix .. '()<CR>', { noremap = true, silent = true })

-- win_move
local windowMoveLayer = libmodal.Layer.new({
  ['n'] = {
    ['+'] = {
      ['rhs'] = '<C-w>+',
      ['noremap'] = true,
      ['silent'] = true,
    },
    ['-'] = {
      ['rhs'] = '<C-w>-',
      ['noremap'] = true,
      ['silent'] = true,
    },
    ['>'] = {
      ['rhs'] = '<C-w>>',
      ['noremap'] = true,
      ['silent'] = true,
    },
    ['<'] = {
      ['rhs'] = '<C-w><',
      ['noremap'] = true,
      ['silent'] = true,
    },
  }
})
prefix = 'Window'
_G[startFunc..prefix], _G[exitFunc..prefix] = generateFunc(windowMoveLayer)
generateEndKeymap(windowMoveLayer, exitFunc..prefix)
vim.api.nvim_set_keymap('n', '<C-w>+', '<C-w>+:lua ' .. startFunc .. prefix .. '()<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<C-w>-', '<C-w>-:lua ' .. startFunc .. prefix .. '()<CR>', { noremap = true, silent = true })

vim.api.nvim_set_keymap('n', '<C-w>>', '<C-w>>:lua ' .. startFunc .. prefix .. '()<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<C-w><', '<C-w><:lua ' .. startFunc .. prefix .. '()<CR>', { noremap = true, silent = true })

-- chunk_move
local chunkMoveLayer = libmodal.Layer.new({
  ['n'] = {
    [']'] = {
      ['rhs'] = ':GitGutterNextHunk<CR>',
      ['noremap'] = true,
      ['silent'] = true,
    },
    ['['] = {
      ['rhs'] = ':GitGutterPrevHunk<CR>',
      ['noremap'] = true,
      ['silent'] = true,
    }
  }
})
prefix = 'chunk'
_G[startFunc..prefix], _G[exitFunc..prefix] = generateFunc(chunkMoveLayer)
generateEndKeymap(chunkMoveLayer, exitFunc..prefix)
vim.api.nvim_set_keymap('n', ']c', ':GitGutterNextHunk<CR>:lua ' .. startFunc .. prefix .. '()<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '[c', ':GitGutterPrevHunk<CR>:lua ' .. startFunc .. prefix .. '()<CR>', { noremap = true, silent = true })

-- search_enhance
local searchMoveLayer = libmodal.Layer.new({
  ['n'] = {
    ['n'] = {
      ['rhs'] = 'ngn<Esc>',
      ['noremap'] = true,
      ['silent'] = true,
    },
    ['N'] = {
      ['rhs'] = 'Ngn<Esc>',
      ['noremap'] = true,
      ['silent'] = true,
    }
  }
})
prefix = 'search'
_G[startFunc..prefix], _G[exitFunc..prefix] = generateFunc(searchMoveLayer)
generateEndKeymap(searchMoveLayer, exitFunc..prefix, {'N', 'n'})
vim.api.nvim_set_keymap('n', 'qn', 'ngn<Esc>:lua ' .. startFunc .. prefix .. '()<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', 'qN', 'Ngn<Esc>:lua ' .. startFunc .. prefix .. '()<CR>', { noremap = true, silent = true })

-- func_enhance
local funcMoveLayer = libmodal.Layer.new({
  ['n'] = {
    [']'] = {
      ['rhs'] = ']]',
      ['noremap'] = true,
      ['silent'] = true,
    },
    ['['] = {
      ['rhs'] = '[[',
      ['noremap'] = true,
      ['silent'] = true,
    }
  }
})
prefix = 'Func'
_G[startFunc..prefix], _G[exitFunc..prefix] = generateFunc(funcMoveLayer)
generateEndKeymap(funcMoveLayer, exitFunc..prefix, {'N', 'n'})
vim.api.nvim_set_keymap('n', ']]', ']]:lua ' .. startFunc .. prefix .. '()<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '[[', '[[:lua ' .. startFunc .. prefix .. '()<CR>', { noremap = true, silent = true })

-- -- quick_enhance
-- local quickMoveLayer = libmodal.Layer.new({
--   ['n'] = {
--     [']'] = {
--       ['rhs'] = ':call qutefinger#next()<CR>',
--       ['noremap'] = true,
--       ['silent'] = true,
--     },
--     ['['] = {
--       ['rhs'] = ':call qutefinger#prev()<CR>',
--       ['noremap'] = true,
--       ['silent'] = true,
--     }
--   }
-- })
-- prefix = 'Quick'
-- _G[startFunc..prefix], _G[exitFunc..prefix] = generateFunc(quickMoveLayer)
-- generateEndKeymap(quickMoveLayer, exitFunc..prefix, {'N', 'n'})
-- vim.api.nvim_set_keymap('n', ']q', ':call qutefinger#next()<CR>:lua ' .. startFunc .. prefix .. '()<CR>', { noremap = true, silent = true })
-- vim.api.nvim_set_keymap('n', '[q', ':call qutefinger#prev()<CR>:lua ' .. startFunc .. prefix .. '()<CR>', { noremap = true, silent = true })

local yankMoveLayer = libmodal.Layer.new({
  ['n'] = {
    ['<C-p>'] = {
      ['rhs'] = ':call miniyank#cycle(1)<CR>',
      ['noremap'] = true,
      ['silent'] = true,
    },
    ['<C-n>'] = {
      ['rhs'] = ':call miniyank#cycle(-1)<CR>',
      ['noremap'] = true,
      ['silent'] = true,
    },
    ['<C-w>'] = {
      ['rhs'] = ':call miniyank#force_motion("v")<CR>',
      ['noremap'] = true,
      ['silent'] = true,
    },
    ['<C-l>'] = {
      ['rhs'] = ':call miniyank#force_motion("V")<CR>',
      ['noremap'] = true,
      ['silent'] = true,
    },
    ['<C-b>'] = {
      ['rhs'] = ':call miniyank#force_motion("b")<CR>',
      ['noremap'] = true,
      ['silent'] = true,
    },
    ['<C-f>'] = {
      ['rhs'] = '=`]^',
      ['noremap'] = true,
      ['silent'] = true,
    }
  }
})
prefix = 'Yank'
_G[startFunc..prefix], _G[exitFunc..prefix] = generateFunc(yankMoveLayer)
generateEndKeymap(yankMoveLayer, exitFunc..prefix)
vim.api.nvim_set_keymap('n', 'p', '<Plug>(miniyank-autoput):lua ' .. startFunc .. prefix .. '()<CR>', {})
vim.api.nvim_set_keymap('n', 'P', '<Plug>(miniyank-autoPut):lua ' .. startFunc .. prefix .. '()<CR>', {})

--
-- Modes
--

local function isEnterkey(input, ignore)
  local keys = {
    'a','b','c','d','e','f','g','h','i',
    'j','k','l','m','n','o','p','q','r',
    's','t','u','v','w','x','y','z',';',
    ':',',','/',''
  }
  if ignore then
    keys = ignoreList(keys, ignore)
  end
  for _, key in pairs(keys) do
    if key == input then
      return true
    end
  end
  return false
end

_G.LibmodalMarkId = nil
local function set_extmark()
  if LibmodalMarkId then
    vim.api.nvim_eval("matchdelete(".. LibmodalMarkId .. ")")
  end
  local line_num = vim.fn.line(".")
  local col_num = vim.fn.col(".")
  LibmodalMarkId = vim.api.nvim_eval("matchadd('Cursor', printf('\\%%%dl\\%%%dc', " .. line_num .. ", " .. col_num .. "))")
end

function _G.set_extmark_and_modal_var(flag)
  set_extmark()
  vim.api.nvim_set_var(flag .. "ModeExit", 0)
end

function BufferMode()
  -- Append to the input history, the latest button press.
  local userInput = string.char(
    -- The input is a character number.
    vim.api.nvim_get_var('bufferModeInput')
  )

  if userInput == ']' then
    vim.api.nvim_command("bnext")
    set_extmark()
  elseif userInput == '[' then
    vim.api.nvim_command("bprev")
    set_extmark()
  elseif isEnterkey(userInput) then
    vim.api.nvim_set_var('bufferModeExit', true)
    vim.api.nvim_eval("matchdelete(".. LibmodalMarkId .. ")")
    LibmodalMarkId = nil
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(userInput,true,false,true),'m',true)
  end
end

-- Enter the mode.
vim.api.nvim_set_keymap('n', ']b',
  ':bnext<CR>:lua set_extmark_and_modal_var("buffer")<CR>:lua require("libmodal").mode.enter("Buffer", BufferMode, true)<CR>', {})
vim.api.nvim_set_keymap('n', '[b',
  ':bprev<CR>:lua set_extmark_and_modal_var("buffer")<CR>:lua require("libmodal").mode.enter("Buffer", BufferMode, true)<CR>', {})

function QuickFixMode()
  -- Append to the input history, the latest button press.
  local userInput = string.char(
    -- The input is a character number.
    vim.api.nvim_get_var('quickfixModeInput')
  )

  if userInput == ']' then
    vim.api.nvim_command("call qutefinger#next()")
    set_extmark()
  elseif userInput == '[' then
    vim.api.nvim_command("call qutefinger#prev()")
    set_extmark()
  elseif isEnterkey(userInput) then
    vim.api.nvim_set_var('quickfixModeExit', true)
    vim.api.nvim_eval("matchdelete(".. LibmodalMarkId .. ")")
    LibmodalMarkId = nil
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(userInput,true,false,true),'m',true)
  end
end

-- Enter the mode.
vim.api.nvim_set_keymap('n', ']q',
  ':call qutefinger#next()<CR>:lua set_extmark_and_modal_var("quickfix")<CR>:lua require("libmodal").mode.enter("QuickFix", QuickFixMode, true)<CR>', {})
vim.api.nvim_set_keymap('n', '[q',
  ':call qutefinger#prev()<CR>:lua set_extmark_and_modal_var("quickfix")<CR>:lua require("libmodal").mode.enter("QuickFix", QuickFixMode, true)<CR>', {})
