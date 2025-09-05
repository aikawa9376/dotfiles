#!/bin/bash

output_path="$XDG_CONFIG_HOME/nvim/lua/sources/nerdfont.lua"
source_url="https://raw.githubusercontent.com/ryanoasis/nerd-fonts/master/glyphnames.json"

COLOR='\27[36m'
RESET='\27[0m'

# Create output directory if it doesn't exist
mkdir -p "$(dirname "$output_path")"

# Start the Lua file
echo 'local function get()
  return {' > "$output_path"

# Download and process JSON
curl -sL "$source_url" | jq -r 'to_entries | .[] | select(.key != "METADATA") | "\(.key) \(.value.code)"' | while read -r name codepoint; do
    if [ -n "$codepoint" ]; then
        # Convert codepoint to UTF-8 character using perl with proper UTF-8 handling
        icon=$(perl -CS -e 'binmode(STDOUT, ":utf8"); print chr(hex("'$codepoint'"))')
        echo "    \"${COLOR}${icon}${RESET} :$name\"," >> "$output_path"
    fi
done

# End the Lua file
echo '  }
end
return { get = get }' >> "$output_path"

echo "✅ nerdfont complete"
