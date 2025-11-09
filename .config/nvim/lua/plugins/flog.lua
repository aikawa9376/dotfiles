return {
  "rbong/vim-flog",
  cmd = { "Flog", "Flogsplit", "Floggit" },
  config = function()
    vim.g.flog_enable_dynamic_commit_hl = true
    vim.g.flog_enable_extended_chars = true

    vim.g.flog_default_opts = {
      format = '%ad %an [%h]%d%n%s',
      date = 'short',
      max_count = 2000
    }

    vim.api.nvim_create_autocmd('FileType', {
      pattern = 'floggraph',
      callback = function()
        vim.opt_local.list = false
        vim.opt_local.number = false

        vim.api.nvim_set_hl(0, 'flogBranch1', { fg = '#8aa872', bold = true })  -- Green
        vim.api.nvim_set_hl(0, 'flogBranch2', { fg = '#d6746f', bold = true })  -- Orange
        vim.api.nvim_set_hl(0, 'flogBranch3', { fg = '#d84f76', bold = true })  -- Red
        vim.api.nvim_set_hl(0, 'flogBranch4', { fg = '#d871a6', bold = true })  -- Violet
        vim.api.nvim_set_hl(0, 'flogBranch5', { fg = '#e6a852', bold = true })  -- Yellow
        vim.api.nvim_set_hl(0, 'flogBranch6', { fg = '#7bb8c1', bold = true })  -- Cyan
        vim.api.nvim_set_hl(0, 'flogBranch7', { fg = '#4a869c', bold = true })  -- Blue
        -- ハッシュ - 黄色
        vim.api.nvim_set_hl(0, 'flogHash', { fg = '#586e75' })
        -- 著者名 - シアン
        vim.api.nvim_set_hl(0, 'flogAuthor', { fg = '#e6a852' })
        -- 日付 - グレー
        vim.api.nvim_set_hl(0, 'flogDate', { fg = '#7bb8c1' })
        -- ブランチ/タグ - マゼンタ
        vim.api.nvim_set_hl(0, 'flogRef', { fg = '#d871a6' })
      end,
    })
  end,
}
