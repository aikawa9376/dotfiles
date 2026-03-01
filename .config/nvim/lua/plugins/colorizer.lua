return {
  "NvChad/nvim-colorizer.lua",
  event = "BufReadPre",
  opts = {
    filetypes = { "*", "!fugitive", "!noice" },
    options = {
      parsers = {
        hex = {
          enable = true,
          rgb = true,       -- #RGB
          rgba = false,     -- #RGBA
          rrggbb = true,    -- #RRGGBB
          rrggbbaa = false, -- #RRGGBBAA
          aarrggbb = false, -- 0xAARRGGBB
        },
        names = { enable = false },
        rgb = { enable = true },  -- rgb()/rgba()
        hsl = { enable = true },  -- hsl()/hsla()
        tailwind = { enable = true, lsp = false },
        sass = { enable = false, parsers = { css = true } },
      },
      display = {
        mode = "virtualtext",
        virtualtext = { char = "●", position = "eol", hl_mode = "foreground" },
      },
    },
    buftypes = { "*", "!prompt", "!popup" },
  }
}
