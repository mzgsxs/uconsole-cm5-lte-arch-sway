#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias ll="ls -l -a"
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias diff='diff --color=auto'
alias ip='ip -color=auto'

# Coloured prompt: green user@host, blue path.
PS1='\[\e[1;32m\]\u@\h\[\e[0m\] \[\e[1;34m\]\w\[\e[0m\] \$ '

# Colour in less and man pages.
export LESS='-R'
export MANPAGER='less -R --use-color -Dd+r -Du+b'

# Attach to the tmux session restored by tmux-continuum, or start a fresh one.
alias ta='tmux attach || tmux new -s main'
