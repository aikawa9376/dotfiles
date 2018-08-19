export PATH="/usr/local/bin:$PATH"
export ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=cyan"
PS1="%{$fg[cyan]%}%1~ %(!.#.$)${reset_color}"

# -------------------------------------
# fzf 
# -------------------------------------
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
export FZF_DEFAULT_COMMAND='rg --files --hidden --glob "!.git"'
export FZF_DEFAULT_OPTS='--height 40% --reverse --border'

# -------------------------------------
# antigen
# -------------------------------------
source ~/.zsh/antigen/antigen.zsh
# zsh-completions
antigen bundle zsh-users/zsh-completions
# zsh-syntax-highlighting
antigen bundle zsh-users/zsh-syntax-highlighting
# anyframe
antigen bundle mollifier/anyframe
# k
antigen bundle supercrabtree/k
# autosuggestions
antigen bundle zsh-users/zsh-autosuggestions

antigen apply

# -------------------------------------
# 補完機能
# -------------------------------------

# 補完機能の強化
autoload -U compinit
compinit
#autoload predict-on
#predict-on

#補完に関するオプション
setopt auto_param_slash      # ディレクトリ名の補完で末尾の / を自動的に付加し、次の補完に備える
setopt mark_dirs             # ファイル名の展開でディレクトリにマッチした場合 末尾に / を付加
setopt list_types            # 補完候補一覧でファイルの種別を識別マーク表示 (訳注:ls -F の記号)
setopt auto_menu             # 補完キー連打で順に補完候補を自動で補完
setopt auto_param_keys       # カッコの対応などを自動的に補完
setopt interactive_comments  # コマンドラインでも # 以降をコメントと見なす
setopt magic_equal_subst     # コマンドラインの引数で --prefix=/usr などの = 以降でも補完できる

setopt complete_in_word      # 語の途中でもカーソル位置で補完
setopt always_last_prompt    # カーソル位置は保持したままファイル名一覧を順次その場で表示

setopt print_eight_bit       # 日本語ファイル名等8ビットを通す
setopt extended_glob         # 拡張グロブで補完(~とか^とか。例えばless *.txt~memo.txt ならmemo.txt 以外の *.txt にマッチ)
setopt globdots              # 明確なドットの指定なしで.から始まるファイルをマッチ

setopt list_packed           # リストを詰めて表示

bindkey "^I" menu-complete   # 展開する前に補完候補を出させる(Ctrl-iで補完するようにする)

# 補完候補を ←↓↑→ でも選択出来るようにする
zstyle ':completion:*:default' menu select=2

# 補完関数の表示を過剰にする編
zstyle ':completion:*' verbose yes
zstyle ':completion:*' completer _expand _complete _match _prefix _approximate _list _history
zstyle ':completion:*:messages' format $YELLOW'%d'$DEFAULT
zstyle ':completion:*:warnings' format $RED'No matches for:'$YELLOW' %d'$DEFAULT
zstyle ':completion:*:descriptions' format $YELLOW'completing %B%d%b'$DEFAULT
zstyle ':completion:*:corrections' format $YELLOW'%B%d '$RED'(errors: %e)%b'$DEFAULT
zstyle ':completion:*:options' description 'yes'

# グループ名に空文字列を指定すると，マッチ対象のタグ名がグループ名に使われる。
# したがって，すべての マッチ種別を別々に表示させたいなら以下のようにする
zstyle ':completion:*' group-name ''

#LS_COLORSを設定しておく
export LS_COLORS='di=34:ln=35:so=32:pi=33:ex=31:bd=46;34:cd=43;34:su=41;30:sg=46;30:tw=42;30:ow=43;30'
#ファイル補完候補に色を付ける
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}

# -------------------------------------
# 補正機能
# -------------------------------------
## 入力しているコマンド名が間違っている場合にもしかして：を出す。
setopt correct

# -------------------------------------
# ディレクト移動
# -------------------------------------
setopt auto_cd
setopt auto_pushd

# -------------------------------------
# コマンド履歴
# -------------------------------------
HISTFILE=~/.zsh_history
HISTSIZE=6000000
SAVEHIST=6000000
setopt hist_ignore_dups     # ignore duplication command history list
setopt share_history        # share command history data
# コマンド履歴検索
autoload history-search-end
zle -N history-beginning-search-backward-end history-search-end
zle -N history-beginning-search-forward-end history-search-end
bindkey "^P" history-beginning-search-backward-end
bindkey "^N" history-beginning-search-forward-end
