# agentify.nvim

`agentify.nvim` is a Codex-backed inline autocomplete plugin for Neovim `0.10+`.

V1 is intentionally narrow:
- one provider abstraction, with `codex app-server` as adapter `#1`
- plugin-managed local `stdio` child process
- existing Codex CLI auth on the machine
- stateless, context-only, single-line suggestions
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

vim.keymap.set("i", "<M-l>", function()
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
    max_context_lines = {
      before = 20,
      after = 20,
    },
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
    service_tier = nil,
    base_instructions = nil,
    refresh_account_token = false,
  },
  logging = {
    level = "warn",
    max_entries = 200,
  },
})
```

## Behavior

- automatic suggestions are debounced on `TextChangedI` and `TextChangedP`
- manual trigger uses the same request path as auto-trigger
- stale turns are ignored when the buffer changes, the cursor moves, or insert mode exits
- suggestions are rendered as inline ghost text with a single extmark
- accept full, accept next word, and dismiss are exposed as Lua APIs

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

- multiline suggestions
- tool use during completion turns
- hidden auth flows or approval prompts while typing
- support below Neovim `0.10`
- multi-provider support in the first shipping milestone

## Testing

Run the unit suite:

```sh
make test
```

Run the live Codex smoke test in a logged-in environment:

```sh
nvim --headless -u tests/minimal_init.lua "+luafile scripts/smoke.lua"
```
