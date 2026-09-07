" Colour
syntax on
set background=dark
set termguicolors

" Soft tabs: never insert a literal tab character.
set expandtab
set tabstop=4
set shiftwidth=4
set softtabstop=4
set shiftround
set autoindent
set smartindent

" Quality of life
set number
set ruler
set incsearch
set hlsearch
set ignorecase
set smartcase
set showmatch
set wrap
set mouse=a
set backspace=indent,eol,start

" Makefiles genuinely require hard tabs.
autocmd FileType make setlocal noexpandtab
