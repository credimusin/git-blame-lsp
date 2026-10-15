# git-blame-lsp

A blazingly fast, lightweight Language Server Protocol (LSP) server tailored for **Helix** and other LSP-compatible editors. It provides inline Git Blame, commit history, and visual Before/After diff previews directly in the hover tooltip.

Written in **Zig** with zero external dependencies.

---

## Features

- **Visual Diff Preview (Before / After)**: On locally changed lines, displays the exact diff hunk against `HEAD` — including unsaved edits in the editor buffer, just like the Helix diff gutter.
- **Deleted Lines**: On the line under a deletion marker (`▔` in the Helix gutter), shows the removed lines, who wrote them, and the blame of the line itself.
- **Smart Auto-Dedenting**: Strips common leading whitespace from diff blocks for clean, readable terminal formatting.
- **Lazygit-Style File Stats**: Displays file status and modification counters (e.g. `M Controller.php (+4/-1)`).
- **Previous Commit Resolution**: For changed or deleted lines, shows the commit that last touched the old version of the line: author, date, and message.
- **Clean PR Summaries**: Automatically simplifies merge messages (e.g. `Merge pull request #12 ...` → `PR #12 ...`).
- **Standard Git Blame**: For committed lines, shows commit SHA, author name, timestamp, and summary.
- **Native & Ultra Lightweight**: Compiles into a single standalone static binary (~600 KB stripped) with sub-millisecond response times (< 1ms).

---

## Installation

### One-liner Build & Install to `~/.local/bin`

Make sure `~/.local/bin` is in your `$PATH`:

```bash
git clone https://github.com/credimusin/git-blame-lsp.git ~/git-blame-lsp # or your local path
cd ~/git-blame-lsp

# Build, install directly to ~/.local/bin and strip debug symbols:
zig build -Doptimize=ReleaseFast -p ~/.local && strip ~/.local/bin/git-blame-lsp
```

---

## Helix Editor Configuration

Helix supports multiple LSPs per language and merges their hover output.

Add the following to your `~/.config/helix/languages.toml`:

```toml
# 1. Register git-blame-lsp
[language-server.git-blame]
command = "git-blame-lsp"

# 2. Add "git-blame" to your languages alongside other LSPs:
[[language]]
name = "zig"
language-servers = ["zls", "git-blame"]
```

After updating `languages.toml`, reload your configuration inside Helix by running `:config-reload` or restarting the editor.

---

## Usage in Helix

1. Open any file in a Git repository.
2. Place the cursor on any line.
3. Press **`Space + k`** (`hover`).

### Preview Examples:

**On a locally modified line (saved or not):**
````markdown
`M Controller.php (+4/-1)`
```diff
- public function init()
+ /**
+  * @return array<string, mixed>
+  */
+ private function initUpdated(User $user): array
```
`Prev: 4cff441f • BMO • 2026-03-18`  
  ↳ *PR #12 from credimusin/feature/init-updates*
````

**On the line under a deletion marker:**
````markdown
`M Controller.php (+0/-2)`
```diff
- $legacy = true;
- $this->boot();
```
`Prev: 4cff441f • BMO • 2026-03-18`  
  ↳ *PR #12 from credimusin/feature/init-updates*

`Blame: 2fa60c8b • Maksim B • 2026-03-29`  
  ↳ *Init Added.*
````

**On an existing committed line:**
```markdown
`Blame: 2fa60c8b • Maksim B • 2026-03-29`  
  ↳ *Init Added.*
```

---

## Development

Run in debug mode or run tests:

```bash
zig build
zig build test
```

---

## License

[MIT](LICENSE)

