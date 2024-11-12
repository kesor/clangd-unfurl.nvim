# clangd-unfurl.nvim

Unfurl #include directives in C files for enhanced LSP support in Neovim

## Introduction

clangd-unfurl.nvim is a Neovim plugin that expands local #include
"file.h" directives directly within your C files. This provides the
clangd language server with the full context of all included files,
improving code analysis and reducing false positives, such as warnings
about unused variables.

## Features

* Recursive Unfurling: Recursively expands local includes while preventing circular dependencies.
* Enhanced LSP Support: Provides clangd with complete code context for better diagnostics.
* Editable Virtual Buffer: Allows editing included files directly within the unfurled virtual buffer.
* Change Tracking: Maps changes back to original files, enabling synchronized edits.
* Visual Boundaries: Highlights the start and end of included files for clarity.

## Requirements

* Neovim 0.5+ with Lua support
* clangd language server

## Installation

Use your preferred Neovim plugin manager.

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'kesor/clangd-unfurl.nvim',
  config = function()
    require('clangd-unfurl').setup()
  end
}
```

### Using [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'kesor/clangd-unfurl.nvim'
lua require('clangd-unfurl').setup()
```

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "kesor/clangd-unfurl.nvim",
  config = function()
    require('clangd-unfurl').setup()
  end
}
```

## Usage

In a C file, run the command:

```vim
:UnfurlC
```

This will open a new split window with the unfurled content.

After editing, save changes back to the original files with:

```vim
:UnfurlSave
```

### Navigation

* **Boundary Lines**: Boundary lines are highlighted and read-only.
* **Cursor Movement**: The cursor will skip over boundary lines automatically.

## Limitations

* **External Modifications**: Changes to original files after unfurling are not detected.
* **Conditional Includes**: Does not handle conditional compilation directives like #ifdef.

## Contributing

Contributions are welcome! Please submit issues and pull requests via [GitHub](https://github.com/kesor/clangd-unfurl.nvim).

## License

This project is licensed under the MIT License. See the [LICENSE](https://github.com/kesor/clangd-unfurl.nvim/blob/main/LICENSE) file for details.
