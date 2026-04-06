# agentify.nvim

`agentify.nvim` is a Codex-backed inline autocomplete plugin for Neovim `0.10+`.

This is still a work-in-progress project. It is being developed and tested day to day by Ranveer Sequeira as a daily-use plugin. If you hit an issue, please open an issue or send a PR.

V1 is intentionally narrow:
- one provider abstraction, with `codex app-server` as adapter `#1`
- plugin-managed local `stdio` child process
- existing Codex CLI auth on the machine
- stateless, context-only suggestions, with multiline only at end-of-line
- LSP-aware fast suggestions when an attached language server can help
- fast structural templates for common patterns like JS/TS arrow-function blocks, JS/TS `console.log(...)`, and Python/Lua `print(...)`
- fast local buffer reuse for repeated identifiers and repeated lines
- explicit status/setup commands instead of silent failure

## Requirements

- Neovim `0.10+`
- `codex` CLI on `PATH`
- an authenticated Codex session on the machine

## Install

With `lazy.nvim`:

```lua
{
  "ixigo/agentify.nvim",
  config = function()
    require("agentify").setup()
  end,
}
```

Minimal setup with keymaps:

```lua
require("agentify").setup({
  debounce_ms = 175,
  filetypes = {
    allow = { "lua", "python", "javascript", "typescript" },
    deny = {},
  },
})

vim.keymap.set("i", "<C-l>", function()
  require("agentify").accept()
end)

vim.keymap.set("i", "<M-w>", function()
  require("agentify").accept_word()
end)

vim.keymap.set("i", "<M-]>", function()
  require("agentify").dismiss()
end)
```

## Commands

- `:AgentifyStatus` checks provider readiness, auth state, rate-limit visibility, and current buffer eligibility.
- `:AgentifySetup` prints actionable setup guidance without forcing prompts into insert mode.
- `:AgentifySuggest` manually requests a suggestion for the current cursor position.

## Configuration

Defaults:

```lua
require("agentify").setup({
  enabled = true,
  provider = "codex",
  debounce_ms = 175,
  suggestion = {
    min_chars = 3,
    highlight = "Comment",
    multiline = true,
    max_lines = 4,
    max_context_lines = {
      before = 8,
      after = 8,
    },
  },
  local_suggestions = {
    enabled = true,
    min_chars = 3,
    max_scan_lines = 400,
    max_suffix_length = 80,
  },
  lsp = {
    enabled = true,
    min_chars = 2,
    timeout_ms = 80,
    max_completion_items = 8,
    max_diagnostics = 3,
  },
  filetypes = {
    allow = {
      "bash",
      "c",
      "cpp",
      "go",
      "javascript",
      "javascriptreact",
      "json",
      "lua",
      "python",
      "rust",
      "sh",
      "toml",
      "typescript",
      "typescriptreact",
      "vim",
      "yaml",
      "zsh",
    },
    deny = {},
  },
  codex = {
    command = { "codex", "app-server" },
    model = nil,
    effort = "none",
    service_tier = nil,
    base_instructions = nil,
    refresh_account_token = false,
    warmup_on_insert = true,
  },
  logging = {
    level = "warn",
    max_entries = 200,
  },
})
```

## Behavior

- automatic suggestions are debounced on `TextChangedI` and `TextChangedP`
- auto suggestions first try structural templates, then fast local buffer reuse, then bounded LSP completions, and finally Codex
- manual trigger always goes through Codex
- stale turns are ignored when the buffer changes, the cursor moves, or insert mode exits
- multiline suggestions are allowed only when the cursor is at end-of-line
- suggestions are rendered as inline ghost text, with trailing lines shown as virtual lines when needed
- accept full, accept next word, and dismiss are exposed as Lua APIs
- Codex is warmed on `InsertEnter` for enabled buffers to reduce first-request latency

## Troubleshooting

If `:AgentifyStatus` says the CLI is missing:

```sh
codex app-server --help
```

If it says authentication is missing:

```sh
codex login
```

If the transport starts but suggestions do not appear:
- confirm the buffer filetype is allowlisted
- confirm you are in insert mode
- run `:AgentifySuggest` to bypass debounce
- raise `logging.level = "debug"` and re-run `:AgentifyStatus`

## Non-goals

- tool use during completion turns
- hidden auth flows or approval prompts while typing
- support below Neovim `0.10`
- multi-provider support in the first shipping milestone

## Testing

Run the unit suite:

```sh
make test
```

Run the headless smoke test:

```sh
nvim --headless -u tests/minimal_init.lua "+luafile scripts/smoke.lua"
```
