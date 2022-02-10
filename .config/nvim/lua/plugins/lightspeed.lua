local labels = {"a", "b", "c", "d", "e", "f", "g", "h", "i", "j",
                "k", "l", "m", "n", "o", "p", "q", "r", "s", "t",
                "u", "v", "w", "x", "y", "z", "z", ".", "'", "/"}

require'lightspeed'.setup {
    -- jump_to_first_match = true,
    limit_ft_matches = 100,
    jump_to_unique_chars = { safety_timeout = 5000 },
    exit_after_idle_msecs = { labeled = nil, unlabeled = nil },
    special_keys = {
      next_match_group = '<Tab>',
      prev_match_group = '<S-Tab>',
    },
    labels = {},
    safe_labels = labels,
}
