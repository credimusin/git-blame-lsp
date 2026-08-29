# git-blame-lsp

A blazingly fast, lightweight Language Server Protocol (LSP) server tailored for **Helix** and other LSP-compatible editors. It provides inline Git Blame, commit history, and visual Before/After diff previews directly in the hover tooltip.

Written in **Zig** with zero external dependencies.

---

## ✨ Features

- **Visual Diff Preview (Before / After)**: On locally modified / uncommitted lines, displays the exact diff hunk showing what changed in the current session.
- **Smart Auto-Dedenting**: Strips common leading whitespace from diff blocks for clean, readable terminal formatting.
- **Lazygit-Style File Stats**: Displays file status and modification counters (e.g. `M PwaController.php (+30/-13)`).
- **Previous Commit Resolution**: For uncommitted lines, finds and shows the previous commit author, relative date, and commit message.
- **Clean PR Summaries**: Automatically simplifies merge messages (e.g. `Merge pull request #12 ...` → `PR #12 ...`).
- **Standard Git Blame**: For committed lines, shows commit SHA, author name, timestamp, and summary.
- **Native & Ultra Lightweight**: Compiles into a single standalone static binary (~600 KB stripped) with sub-millisecond response times (< 1ms).

---

## 🚀 Installation

### One-liner Build & Install to `~/.local/bin`

Make sure `~/.local/bin` is in your `$PATH`:

```bash
git clone https://github.com/your-username/git-blame-lsp.git ~/Devs/git-blame-lsp # or your local path
cd ~/Devs/git-blame-lsp

# Build, install directly to ~/.local/bin and strip debug symbols:
zig build -Doptimize=ReleaseFast -p ~/.local && strip ~/.local/bin/git-blame-lsp
```

---

## ⚙️ Helix Editor Configuration

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

[[language]]
name = "rust"
language-servers = ["rust-analyzer", "git-blame"]

[[language]]
name = "python"
language-servers = ["pyright", "ruff", "git-blame"]

[[language]]
name = "go"
language-servers = ["gopls", "git-blame"]

[[language]]
name = "typescript"
language-servers = ["typescript-language-server", "git-blame"]

[[language]]
name = "php"
language-servers = ["intelephense", "git-blame"]
```

After updating `languages.toml`, reload your configuration inside Helix by running `:config-reload` or restarting the editor.

---

## 🎯 Usage in Helix

1. Open any file in a Git repository.
2. Place the cursor on any line.
3. Press **`Space + k`** (`hover`).

### Preview Examples:

**On a locally modified line (uncommitted):**
````markdown
```diff
- public function init()
+ /**
+  * @return array<string, mixed>
+  */
+ private function getSyncPayload(Student $student, User $user): array
```
`M PwaController.php (+30/-13)`

• Prev: `4cff441f` • BMO (11 days ago)
> PR #12 from credimusin/feature/teachers-updates
````

**On an existing committed line:**
```markdown
`Blame: 2fa60c8b • Maksim B • 2026-03-29`
> PWA Added.
```

---

## 🛠️ Development

Run in debug mode or run tests:

```bash
zig build
zig build test
```

## License

MIT
