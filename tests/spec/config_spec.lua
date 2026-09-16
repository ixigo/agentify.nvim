local config = require("agentify.config")
local h = require("tests.helpers")

return {
  {
    name = "normalizes custom filetype config",
    fn = function()
      local opts = config.normalize({
        debounce_ms = 120,
        filetypes = {
          allow = { "lua" },
          deny = { "markdown" },
        },
      })

      h.eq(120, opts.debounce_ms)
      h.eq({ "lua" }, opts.filetypes.allow)
      h.eq({ "markdown" }, opts.filetypes.deny)
      h.eq(true, opts.lsp.enabled)
      h.eq(2, opts.lsp.min_chars)
      h.eq(true, opts.intent.enabled)
      h.eq(4, opts.intent.max_open_buffers)
    end,
  },
  {
    name = "rejects invalid debounce",
    fn = function()
      local ok, err = pcall(config.normalize, {
        debounce_ms = 0,
      })

      h.eq(false, ok)
      h.match("debounce_ms", err)
    end,
  },
  {
    name = "checks filetype allowlist",
    fn = function()
      local opts = config.normalize({
        filetypes = {
          allow = { "lua" },
          deny = {},
        },
      })

      h.with_buffer({ "local value = 1" }, function(bufnr)
        vim.bo[bufnr].filetype = "lua"
        local enabled = config.is_buffer_enabled(opts, bufnr)
        h.eq(true, enabled)
      end)
    end,
  },
  {
    name = "defaults to the auto provider with subscription-only auth",
    fn = function()
      local opts = config.normalize({})

      h.eq("auto", opts.provider)
      h.eq("extmark", opts.frontend)
      h.eq(true, opts.warmup_on_insert)
      h.eq(true, opts.auth.subscription_only)
      h.eq({ "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY" }, opts.auth.strip_env)
      h.eq({ "claude" }, opts.providers.claude.command)
      h.eq("haiku", opts.providers.claude.model)
      h.eq("sonnet", opts.providers.claude.manual_model)
      h.eq(40, opts.providers.claude.max_session_turns)
      h.eq({ "codex", "app-server" }, opts.providers.codex.command)
      h.eq({}, opts.deprecations)
    end,
  },
  {
    name = "migrates the legacy codex table into providers.codex",
    fn = function()
      local opts = config.normalize({
        codex = {
          model = "gpt-5-codex",
          warmup_on_insert = false,
        },
      })

      h.eq("gpt-5-codex", opts.providers.codex.model)
      h.eq(false, opts.warmup_on_insert)
      h.eq(nil, opts.codex)
      h.eq(1, #opts.deprecations)
      h.match("providers.codex", opts.deprecations[1])
    end,
  },
  {
    name = "rejects unknown providers and frontends",
    fn = function()
      local ok, err = pcall(config.normalize, { provider = "copilot" })
      h.eq(false, ok)
      h.match("provider must be one of", err)

      local ok_frontend, err_frontend = pcall(config.normalize, { frontend = "popup" })
      h.eq(false, ok_frontend)
      h.match("frontend must be one of", err_frontend)

      local ok_cmd, err_cmd = pcall(config.normalize, { providers = { claude = { command = {} } } })
      h.eq(false, ok_cmd)
      h.match("providers.claude.command", err_cmd)
    end,
  },
  {
    name = "an empty override table keeps dict defaults but clears list defaults",
    fn = function()
      local opts = config.normalize({
        budget = {},
        lsp = {},
        paths = { deny = {} },
        providers = { claude = { extra_args = {} } },
      })

      h.eq(300, opts.budget.max_requests_per_hour)
      h.eq(true, opts.lsp.enabled)
      h.eq({}, opts.paths.deny)
      h.eq({}, opts.providers.claude.extra_args)
    end,
  },
}
