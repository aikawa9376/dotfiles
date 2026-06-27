# Neovim dictionaries

`romaji-japanese.tsv` is a small local override dictionary for
`blink_extension.completion.romaji_japanese`.

Large SKK dictionaries are downloaded from:

https://skk-dev.github.io/dict/

They are ignored by git. The current default source always loads the small
local override dictionary and uses the registry below for large SKK
dictionaries.

Additional local dictionary files can be registered from Neovim:

```vim
:RomajiJapaneseDict init
:RomajiJapaneseDict add /path/to/SKK-JISYO.user
:RomajiJapaneseDict download ML
:RomajiJapaneseDict list
:RomajiJapaneseDict status
:RomajiJapaneseDict reload
```

`:RomajiJapaneseDict init` enables the recommended set. It registers existing
files when they are already present, downloads missing files, and preloads the
dictionary cache. The default recommended set is:

- `SKK-JISYO.L.unannotated`
- `SKK-JISYO.propernoun`

Registered paths are written to `romaji-japanese-dicts.txt`, which is ignored
by git because it may contain machine-local absolute paths.

```sh
curl -fL https://skk-dev.github.io/dict/SKK-JISYO.L.unannotated.gz -o SKK-JISYO.L.unannotated.gz
gunzip -f SKK-JISYO.L.unannotated.gz
iconv -f EUC-JP -t UTF-8 SKK-JISYO.L.unannotated -o SKK-JISYO.L.unannotated.utf8
mv -f SKK-JISYO.L.unannotated.utf8 SKK-JISYO.L.unannotated
```
