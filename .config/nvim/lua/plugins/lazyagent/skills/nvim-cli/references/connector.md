# connector.nvim

Use connector.nvim through the active Neovim instance.

```bash
$LAZYAGENTBIN/nvim-cli-bridge connector context
$LAZYAGENTBIN/nvim-cli-bridge connector connections
$LAZYAGENTBIN/nvim-cli-bridge connector query --format table 'select * from users limit 20'
$LAZYAGENTBIN/nvim-cli-bridge connector execute --write --format table 'insert into users(name) values ("alice")'
```

Safety:

- `connector query` refuses mutating SQL.
- `connector execute` refuses mutating SQL unless `--write` or `--allow-write` is present.
- Prefer `--format json` when you need structured rows.
