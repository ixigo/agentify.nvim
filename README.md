# agentify.nvim

```text
                        _   _  __                    _
  __ _  __ _  ___ _ __ | |_(_)/ _|_   _   _ ____   _(_)_ __ ___
 / _` |/ _` |/ _ \ '_ \| __| | |_| | | | | '_ \ \ / / | '_ ` _ \
| (_| | (_| |  __/ | | | |_| |  _| |_| |_| | | \ V /| | | | | | |
 \__,_|\__, |\___|_| |_|\__|_|_|  \__, (_)_| |_|\_/ |_|_| |_| |_|
       |___/                      |___/
```

`agentify.nvim` is a Codex-backed inline completion plugin for Neovim `0.10+`.

It is built for people who want useful completions without leaving insert mode. The plugin keeps the flow lightweight: it can reuse nearby code and LSP context for fast suggestions, then lean on Codex when the line needs real intent instead of simple suffix matching.

## Why use it

- Inline ghost-text completions that stay inside your normal editing flow
- Uses your existing local `codex` CLI session, so there is no extra auth UI inside Neovim
- Pulls signal from the current line, nearby code, LSP context, symbol names, and related open buffers
- Supports full accept, word-by-word accept, dismiss, and manual trigger
- Optimized for practical latency with fast local/template suggestions and Codex upgrades when needed

## What it is good at

- Filling in function bodies from descriptive names such as `convertArrayToString`
- Expanding common editing patterns like JS/TS arrow-function blocks
- Helping with quick debug statements such as `console.log(...)` and `print(...)`
- Reusing identifiers and repeated lines from the current buffer
- Staying out of the way when the cursor moves or the buffer changes

## Scope

This project is intentionally narrow right now:

- one provider: Codex through `codex app-server`
- plugin-managed local `stdio` transport
- existing Codex CLI authentication on the machine
- inline suggestions only, with multiline suggestions only at end-of-line
- Neovim `0.10+`

## Requirements

- Neovim `0.10+`
- `codex` on `PATH`
- an authenticated Codex CLI session on the same machine

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

A practical setup with common keymaps:

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

## Daily usage

- Start typing in insert mode and wait for the debounce window to pass.
- Accept the whole suggestion with `require("agentify").accept()`.
- Accept the next word with `require("agentify").accept_word()`.
- Dismiss the current suggestion with `require("agentify").dismiss()`.
- Use `:AgentifySuggest` when you want to force a manual Codex request.
- Use `:AgentifyStatus` when something feels off.
- Use `:AgentifySetup` when you want actionable setup guidance.

## Commands

- `:AgentifyStatus` shows provider readiness, auth visibility, transport state, rate-limit info, and whether the current buffer is eligible.
- `:AgentifySetup` prints focused setup help when the CLI or auth state is missing.
- `:AgentifySuggest` manually requests a suggestion at the cursor.

## Configuration

Most people only need to adjust a small number of options:

- `debounce_ms` controls how quickly auto-suggestions appear.
- `filetypes.allow` and `filetypes.deny` decide where Agentify runs.
- `suggestion.multiline` and `suggestion.max_lines` control multi-line completions.
- `codex.model`, `codex.effort`, and `codex.warmup_on_insert` control Codex behavior.
- `logging.level` helps with troubleshooting.

Full defaults live in [`lua/agentify/config.lua`](lua/agentify/config.lua).

A more opinionated example:

```lua
require("agentify").setup({
  debounce_ms = 140,
  suggestion = {
    multiline = true,
    max_lines = 4,
  },
  codex = {
    effort = "none",
    warmup_on_insert = true,
  },
  logging = {
    level = "warn",
  },
})
```

## Troubleshooting

If `:AgentifyStatus` says the CLI is missing:

```sh
codex app-server --help
```

If authentication is missing:

```sh
codex login
```

If the transport is running but suggestions do not show up:

- confirm the buffer filetype is allowlisted
- confirm you are in insert mode
- run `:AgentifySuggest` to bypass debounce
- set `logging.level = "debug"` and run `:AgentifyStatus` again

## Testing

```sh
make test
```

For a headless smoke run:

```sh
nvim --headless -u tests/minimal_init.lua "+luafile scripts/smoke.lua"
```

## Project status

`agentify.nvim` is actively developed and used day to day. Issues and PRs are welcome.

## License

This project is licensed under the [MIT License](LICENSE).
