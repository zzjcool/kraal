# Where these files come from

Copied verbatim from **Ghostty** (`/Applications/Ghostty.app/Contents/Resources/ghostty/themes/`,
Ghostty 1.1.x), which bundles the themes from
[iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes) plus its own.

Both are open source under the MIT licence; individual themes keep the authorship
recorded in those repositories. Nothing here is copied from Rex — its theme catalogue
was read to learn the *model* (`docs/REX-UI.md`), not to take the colours.

Format: Ghostty's own theme file format, one `key = value` per line:

```
palette = 0=#45475a      ... 16 entries
background = #1e1e2e
foreground = #cdd6f4
cursor-color = #f5e0dc
cursor-text = #1e1e2e
selection-background = #f5e0dc
selection-foreground = #1e1e2e
```

# Adding one

Copy the file from Ghostty's directory, nothing else. `GhosttyThemeCatalogTests`
parses every file here and fails on one it cannot read, so a truncated copy is a red
test rather than a theme that silently paints nothing.
