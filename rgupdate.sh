#!/bin/sh
APIURL=https://api.github.com/repos/BurntSushi/ripgrep/releases/latest
{
    rg --version | tr -d '\n'
    echo -n ' -> '
    curl -s "$APIURL" | jq -r .tag_name
} | sed -e 's/^ripgrep \(.*\) -> \1$/now up to date/'
