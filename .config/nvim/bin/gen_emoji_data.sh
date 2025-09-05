#!/bin/bash

output_path="$XDG_CONFIG_HOME/nvim/lua/sources/emoji.lua"
source_url="https://raw.githubusercontent.com/github/gemoji/master/db/emoji.json"

mkdir -p "$(dirname "$output_path")"

echo 'local function get()
  return {' > "$output_path"

curl -sL "$source_url" | jq -r '.[] | "\(.emoji) \(.aliases[0])"' | while read -r emoji alias; do
    if [ -n "$emoji" ] && [ -n "$alias" ]; then
        echo "    \"$emoji :$alias\"," >> "$output_path"
    fi
done

# Lua ファイルの終了部分を記述
echo '  }
end
return { get = get }' >> "$output_path"

echo "✅ Emoji data generation complete: $output_path"
