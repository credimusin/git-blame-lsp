# git-blame-lsp

A blazingly fast, lightweight Language Server Protocol (LSP) server for inline Git Blame and visual Diff previews in editors like **Helix**.

Written in **Zig**.

## Features

- **Inline Git Blame & History**: Instantly shows commit SHA, author, date, and commit message via LSP hover (`Space + k`).
- **Visual Diff Preview (Before / After)**: On uncommitted / locally modified lines, displays the exact `diff` block showing what changed.
- **Auto-Dedenting**: Strips common leading whitespace from diff lines for a clean terminal preview.
- **Lazygit-style File Stats**: Shows file modification status and diff counters (e.g. `M filename.zig (+12/-3)`).
- **Previous Commit Resolution**: Resolves and displays the prior commit before local edits.
- **PR Summary Shortener**: Automatically compresses `Merge pull request #12 ...` into `PR #12 ...`.
- **Zero Heavy Runtime Dependencies**: Pure compiled native binary (~600 KB stripped), instant startup (< 1ms).

## Build & Install

```bash
# Build optimized release binary
zig build -Doptimize=ReleaseFast

# Strip debug symbols (optional, reduces binary to ~600KB)
strip zig-out/bin/git-blame-lsp

# Install to ~/.local/bin
cp zig-out/bin/git-blame-lsp ~/.local/bin/git-blame-lsp
```

## Helix Configuration

Add to `~/.config/helix/languages.toml`:

```toml
[language-server.git-blame]
command = "git-blame-lsp"

[[language]]
name = "zig"
language-servers = ["zls", "git-blame"]

[[language]]
name = "rust"
language-servers = ["rust-analyzer", "git-blame"]

[[language]]
name = "python"
language-servers = ["pyright", "ruff", "git-blame"]
```
