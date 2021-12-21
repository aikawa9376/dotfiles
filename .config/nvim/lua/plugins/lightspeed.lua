local labels = {"a", "b", "c", "d", "e", "f", "g", "h", "i", "j",
                "k", "l", "m", "n", "o", "p", "q", "r", "s", "t",
                "u", "v", "w", "x", "y", "z", "z", ".", "'", "/"}

require'lightspeed'.setup {
    -- jump_to_first_match = true,
    limit_ft_matches = 100,
    jump_on_partial_input_safety_timeout = 5000,
    exit_after_idle_msecs = { labeled = nil, unlabeled = nil },
    cycle_group_fwd_key = '<Tab>',
    labels = {},
    safe_labels = labels,
}
