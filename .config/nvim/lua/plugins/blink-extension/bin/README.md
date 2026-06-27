# viterust bundle

This directory contains the viterust runtime used by
`blink_extension.completion.romaji_japanese`.

```text
bin/linux-x64/viterust
data/viterust/jawiki-corpus.vtrdict
data/viterust/jawiki-3gram.vtrngram
```

The executable is platform-specific, so it follows the same `bin/<os>-<arch>/`
layout used by lazyagent. The dictionary and ngram files are data files shared
by the Neovim completion source, so they live under the plugin's `data/`
directory.
