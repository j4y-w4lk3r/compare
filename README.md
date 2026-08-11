# compare.yazi

Compare two files or directories in [Yazi](https://github.com/sxyazi/yazi).

Reports whether paths are identical, different, or if one is a subset of the other. Useful for finding duplicate folders (`test` vs `test2`, backup copies, etc.).

## Installation

```sh
ya pkg add j4y-w4lk3r/compare.yazi
```

## Usage

Add to `~/.config/yazi/keymap.toml`:

```toml
# Compare selected vs hovered (or two selected items)
{ on = [ "c", "m" ], run = "plugin compare", desc = "Compare files/directories" },

# Compare tab 1 cwd vs tab 2 cwd
{ on = [ "c", "M" ], run = "plugin compare tabs", desc = "Compare tab directories" },
```

### Modes

| Action | How |
|---|---|
| Two selected | Select two items (visual mode), press `cm` |
| Selected + hovered | Select one item, hover another, press `cm` |
| Two tabs | Open two tabs, press `cM` |

Results appear in a Yazi notification. Full report path is copied to clipboard.

### CLI

The shell script can also be run directly:

```sh
~/.config/yazi/plugins/compare.yazi/compare.sh /path/a /path/b
```

## License

MIT
