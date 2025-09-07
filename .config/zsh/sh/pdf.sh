#!/usr/bin/env zsh

# PDFを閲覧するための関数
viewpdf() {
    # ファイル名が指定されていない場合は使い方を表示
    if [[ -z "$1" ]]; then
        echo "Usage: viewpdf <filename.pdf> [page_number]"
        return 1
    fi

    # 引数を変数に格納
    local pdf_file="$1"
    local page="${2:-1}"  # ページ番号がなければ1をデフォルトにする

    # 指定されたファイルが存在するか確認
    if [[ ! -f "$pdf_file" ]]; then
        echo "Error: File not found - '$pdf_file'"
        return 1
    fi

    # magick convertで指定されたページを変換し、icatで表示
    magick "${pdf_file}[$(($page - 1))]" -
}

# スクリプトが直接実行された場合にviewpdf関数を呼び出す
viewpdf "$@"
