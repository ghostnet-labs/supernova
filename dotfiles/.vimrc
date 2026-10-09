" Disable compatibility with vi which can cause unexpected issues.
set nocompatible

" Turn syntax highlighting on.
syntax enable

" Add numbers to each line on the left-hand side.
set number

" Always show the status line.
set laststatus=2

" Disable showing mode (e.g., INSERT) at the bottom left.
"set noshowmode

" Highlight cursor line underneath the cursor horizontally.
set cursorline

" Add full file path to your existing statusline
"set statusline=%F

" Use spaces instead of tabs (use 4 spaces per indent).
set expandtab
set tabstop=4
set shiftwidth=4
set softtabstop=4
set smartindent
set autoindent

" Set color scheme.
set background=dark
set termguicolors
colorscheme tokyonight-night

" Show matching parentheses, brackets and braces.
set showmatch

" Do not save backup files.
set nobackup

" Do not let cursor scroll below or above N number of lines when scrolling.
set scrolloff=15

" Do not wrap lines. Allow long lines to extend as far as the line goes.
set nowrap

" While searching though a file incrementally highlight matching characters as you type.
set incsearch
set hlsearch

" Ignore case while searching, but make it case-sensitive if there are uppercase letters.
set ignorecase
set smartcase

" Show partial command you type in the last line of the screen.
set showcmd

" Show matching words during a search.
set showmatch

" Set the commands to save in history default number is 20.
set history=1000

" Enable autocompletion for files and commands.
set completeopt=menu,menuone,noselect
