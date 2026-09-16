# agentify.nvim

```text
                        _   _  __                    _
  __ _  __ _  ___ _ __ | |_(_)/ _|_   _   _ ____   _(_)_ __ ___
 / _` |/ _` |/ _ \ '_ \| __| | |_| | | | | '_ \ \ / / | '_ ` _ \
| (_| | (_| |  __/ | | | |_| |  _| |_| |_| | | \ V /| | | | | | |
 \__,_|\__, |\___|_| |_|\__|_|_|  \__, (_)_| |_|\_/ |_|_| |_| |_|
       |___/                      |___/
```

`agentify.nvim` is an inline ghost-text completion plugin for Neovim `0.10+`, powered by the
agent CLIs you already have installed: **Claude Code** (`claude`) and **Codex** (`codex`).

It is built for people who want useful completions without leaving insert mode. The plugin keeps
the flow lightweight: it reuses nearby code and LSP context for instant suggestions, then leans on
a warm Claude or Codex session when the line needs real intent instead of simple suffix matching.

> **Subscription-only by design.** Agentify only talks to CLIs that are signed in with an
> hour-based subscription account: Claude Code via `claude auth login` (claude.ai Pro, Max, or
> Team) and Codex via `codex login` (ChatGPT). API-key billing is refused, and the plugin strips
> `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, and `OPENAI_API_KEY` from every CLI process it
> spawns so a stray key in your shell can never turn autocomplete into a metered bill. See
> [Billing and quota](#billing-and-quota).

## Why use it

- Inline ghost-text completions that stay inside your normal editing flow
- Uses your existing local `claude` or `codex` login, so there is no extra auth UI inside Neovim
- Picks the authenticated CLI automatically, or lets you pin one
- Pulls signal from the current line, nearby code, LSP context, symbol names, and related open buffers
- Supports full accept, word-by-word accept, line accept, dismiss, and manual trigger
- Keeps the ghost text while you type through it, re-shows recent suggestions when you
  backspace, and prefetches the next one right after an accept
- Optimized for practical latency: instant local/template suggestions, sub-second model suggestions
  from a warm Haiku session, and a stronger model only when you ask for it
- Optional Neovim `0.12` frontend that renders through the built-in `vim.lsp.inline_completion`

## What it is good at

- Filling in function bodies from descriptive names such as `convertArrayToString`
- Expanding common editing patterns like JS/TS arrow-function blocks
- Helping with quick debug statements such as `console.log(...)` and `print(...)`
- Reusing identifiers and repeated lines from the current buffer
- Staying out of the way when the cursor moves or the buffer changes

## How it works

Every keystroke in insert mode runs through the same pipeline:

1. **Debounce** (175 ms by default) and a minimum-characters check.
2. **Context**: a few lines around the cursor, LSP diagnostics and completion items, and a light
   intent analysis of the symbol being defined.
3. **Fast tier**: template, buffer-reuse, and LSP suggestions render instantly.
4. **Model tier**: when the line needs intent, the request goes to a warm CLI session and streams
   back as ghost text. Moving the cursor interrupts the turn.

Providers:

| Provider | CLI | Transport | Inline model | Manual `:AgentifySuggest` |
|---|---|---|---|---|
| `claude` | `claude` | `claude -p` with stream-json in/out, one warm process per model | `haiku` | `sonnet` |
| `codex` | `codex app-server` | JSON-RPC over stdio, one warm ephemeral thread | Codex default | Codex default |

With `provider = "auto"` (the default) Agentify checks Claude first and then Codex, and uses the
first one that is installed and signed in with a subscription.

## Scope

- Two providers, both through their local CLIs and existing logins
- Plugin-managed local transports; no network code of its own
- Inline suggestions only, with multiline suggestions only at end-of-line
- Neovim `0.10+`; the `lsp` frontend needs `0.12+`

## Requirements

- Neovim `0.10+`
- At least one of:
  - `claude` on `PATH`, signed in with `claude auth login` (claude.ai account)
  - `codex` on `PATH`, signed in with `codex login` (ChatGPT account)

Claude Code `2.0` or newer is required for the stream-json protocol the plugin uses.

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
  provider = "auto", -- "auto" | "claude" | "codex"
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

vim.keymap.set("i", "<M-l>", function()
  require("agentify").accept_line()
end)

vim.keymap.set("i", "<M-]>", function()
  require("agentify").dismiss()
end)
```

## Daily usage

- Start typing in insert mode and wait for the debounce window to pass.
- Accept the whole suggestion with `require("agentify").accept()`.
- Accept the next word with `require("agentify").accept_word()`; the rest of the suggestion stays visible.
- Accept the first line of a multi-line suggestion with `require("agentify").accept_line()`.
- Keep typing the suggested characters and the ghost text shortens instead of disappearing.
- Backspace into a spot that already had a suggestion and it comes back instantly, without a model call.
- Dismiss the current suggestion with `require("agentify").dismiss()`.
- Use `:AgentifySuggest` to force a manual request. With Claude this uses the stronger
  `manual_model` (Sonnet by default); the first manual request boots that session, so expect a
  few seconds once.
- Use `:AgentifyStatus` when something feels off.
- Use `:AgentifySetup` when you want actionable setup guidance.

## Commands

- `:AgentifyStatus` shows the selected provider, readiness, auth method and plan, transport state,
  session usage or rate limits, and whether the current buffer is eligible.
- `:AgentifySetup` prints focused setup help when a CLI or its login is missing, or when the CLI is
  signed in with API-key billing.
- `:AgentifySuggest` manually requests a suggestion at the cursor.

## Configuration

Most people only need to adjust a small number of options:

- `provider` picks `"auto"`, `"claude"`, or `"codex"`.
- `frontend` picks `"extmark"` (default) or `"lsp"` (Neovim 0.12+, see below).
- `warmup_on_insert` spawns the CLI session when you enter insert mode so the first suggestion is fast.
- `debounce_ms` controls how quickly auto-suggestions appear; `debounce_busy_ms` is used
  instead while a model request is already running.
- `type_through`, `recall`, and `prefetch_after_accept` control the keep-typing, backspace
  recall, and accept-then-prefetch behaviours (all on by default).
- `filetypes.allow` and `filetypes.deny` decide where Agentify runs.
- `suggestion.multiline` and `suggestion.max_lines` control multi-line completions.
- `providers.claude.model`, `providers.claude.manual_model`, and `providers.claude.effort` control Claude.
- `providers.codex.model` and `providers.codex.effort` control Codex.
- `auth.subscription_only` and `auth.strip_env` control the billing guard.
- `logging.level` helps with troubleshooting.

Full defaults live in [`lua/agentify/config.lua`](lua/agentify/config.lua).

A more opinionated example:

```lua
require("agentify").setup({
  provider = "claude",
  debounce_ms = 140,
  suggestion = {
    multiline = true,
    max_lines = 4,
  },
  providers = {
    claude = {
      model = "haiku",          -- inline suggestions
      manual_model = "sonnet",  -- :AgentifySuggest only
      effort = "low",
      max_session_turns = 40,   -- recycle the warm process to keep history small
      extra_args = {},          -- passed through to `claude -p`
    },
    codex = {
      effort = "none",
    },
  },
  logging = {
    level = "warn",
  },
})
```

The older `codex = { ... }` table is still accepted and is folded into `providers.codex` with a
one-time deprecation notice.

## Latency without model calls

Several behaviours make suggestions feel instant while spending nothing from your usage window:

- **Type-through.** When the characters you type match the head of the ghost text, the
  suggestion shrinks in place. No request is sent and any in-flight one is cancelled.
- **Recall.** Every shown suggestion is remembered against its exact cursor context (line,
  prefix, suffix), up to `recall.max_entries` per buffer. Backspacing into that context shows
  it again immediately. An explicit dismiss removes that entry so it does not bounce back.
- **Partial accepts keep the rest.** `accept_word()` and `accept_line()` insert a fragment and
  re-anchor the remainder at the new cursor position.
- **Prefetch after accept.** A full accept asks for the next suggestion right away instead of
  waiting for the next keystroke plus debounce.
- **Adaptive debounce.** While a model request is in flight the debounce widens to
  `debounce_busy_ms`, so a fast burst of typing does not become a burst of interrupted turns.

These apply to the default `extmark` frontend. With `frontend = "lsp"`, Neovim's own inline
completion handles type-through and re-triggering; `accept_line()` and `accept_word()` still
work through its `on_accept` hook.

## Billing and quota

Agentify is meant to run against the hour-based usage windows of a Claude or ChatGPT subscription,
not against a pay-per-token API key.

- `auth.subscription_only = true` (default) makes `:AgentifyStatus` report **not ready** when a CLI
  is signed in with an API key, and `:AgentifySetup` tells you how to switch to a subscription login.
- `auth.strip_env` removes API-key variables from the environment of every spawned CLI, so the CLI
  falls back to its stored subscription login even if your shell exports a key.
- Inline suggestions use Haiku, and the plugin turns off extended thinking, tools, MCP servers,
  settings discovery, and session persistence for that process, which keeps each completion to a
  few hundred tokens.
- The fast tier answers many keystrokes without any model call at all.
- `:AgentifyStatus` shows per-session request and token counts for Claude and remaining rate
  limits for Codex, so you can see how much of your window autocomplete is using.

If you knowingly want API-key billing, set `auth.subscription_only = false` and remove the key
from `auth.strip_env`.

## Neovim 0.12 inline completion frontend

Neovim `0.12` ships `vim.lsp.inline_completion`. With `frontend = "lsp"`, Agentify registers an
in-process language server that answers `textDocument/inlineCompletion`, and Neovim renders,
cycles, and accepts the ghost text itself. This lets Agentify coexist with other inline-completion
sources and with completion plugins that consume the same API.

```lua
require("agentify").setup({
  frontend = "lsp",
})

vim.keymap.set("i", "<Tab>", function()
  if not require("agentify").accept() then
    return "<Tab>"
  end
end, { expr = true })
```

In this mode:

- `require("agentify").accept()` calls `vim.lsp.inline_completion.get()`.
- `require("agentify").accept_word()` and `accept_line()` accept a fragment through the `on_accept` hook.
- `require("agentify").dismiss()` clears the current candidate.
- `:AgentifySuggest` triggers a manual request through the same server.
- Triggering and debouncing are handled by Neovim, so `debounce_ms` does not apply.
- On Neovim older than `0.12` the plugin logs a warning and falls back to `frontend = "extmark"`.

## Troubleshooting

If `:AgentifyStatus` says a CLI is missing:

```sh
claude --version
codex app-server --help
```

If authentication is missing or uses an API key:

```sh
claude auth login
codex login
```

If the transport is running but suggestions do not show up:

- confirm the buffer filetype is allowlisted
- confirm you are in insert mode
- run `:AgentifySuggest` to bypass debounce
- set `logging.level = "debug"` and run `:AgentifyStatus` again

The first Claude suggestion after Neovim starts can take a few seconds while the CLI boots; with
`warmup_on_insert = true` that happens when you first enter insert mode, not when you type.

## Testing

```sh
make test
```

The suite uses a fake `claude` CLI under `tests/fixtures/` that replays recorded stream-json
output, so no network or login is needed.

For a headless smoke run:

```sh
nvim --headless -u tests/minimal_init.lua "+luafile scripts/smoke.lua"
```

## Project status

`agentify.nvim` is actively developed and used day to day. Issues and PRs are welcome.

## License

This project is licensed under the [MIT License](LICENSE).
