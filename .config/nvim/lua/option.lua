local opt = vim.o

opt.fillchars = opt.fillchars .. 'vert: '
opt.encoding='utf-8'
opt.number = true
opt.backspace = 'indent,eol,start'
opt.fileformats = 'unix,dos,mac'
opt.fileencodings = 'utf-8,sjis'
opt.ttimeoutlen = 1
opt.completeopt = 'menuone'
opt.cursorline = true
opt.list = true
opt.undofile = true
opt.undodir='$XDG_CACHE_HOME/nvim/undo/'
opt.listchars='tab:»-,extends:»,precedes:«,nbsp:%,trail:-'
opt.splitright = true
opt.splitbelow = true
opt.updatetime = 100
opt.showmode = false
opt.spell = false
opt.spelllang = 'en,cjk'
opt.shortmess = opt.shortmess .. 'atc'
opt.signcolumn = 'yes'
opt.confirm = true
opt.hidden = true
opt.autoread = true
opt.backup = false
opt.writebackup = false
opt.swapfile = false
opt.switchbuf = 'useopen'
opt.ignorecase = true
opt.smartcase = true
opt.incsearch = true
opt.inccommand = 'split'
opt.hlsearch = true
opt.smartindent = true
opt.breakindent = true
opt.scrolloff = 10
opt.virtualedit = 'onemore'
opt.clipboard = 'unnamed,unnamedplus'
opt.mouse = 'a'
opt.expandtab = true
opt.tabstop = 2
opt.shiftwidth = 2
opt.softtabstop = 2
opt.autoindent = true
opt.smartindent = true
opt.wildmenu = true
opt.wildmode = 'list,full'
opt.wildoptions = opt.wildoptions .. ',pum'
opt.pumblend = 20
opt.winblend = 20
-- opt.shellslash = true
