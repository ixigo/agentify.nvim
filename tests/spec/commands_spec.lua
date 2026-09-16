local commands = require("agentify.commands")
local h = require("tests.helpers")

local function base_report(overrides)
  return vim.tbl_deep_extend("force", {
    provider = "claude",
    provider_label = "Claude Code",
    ready = true,
    frontend = "extmark",
    cli = { available = true, command = { "claude" } },
    transport = { running = true, initialized = true },
    thread = { warm = true },
    auth = { logged_in = true, method = "subscription", label = "dev@example.com", plan = "team" },
    usage = { requests = 3, completed = 2, cancelled = 1, input_tokens = 900, output_tokens = 40 },
    version = "2.1.273",
    buffer = { filetype = "lua", enabled = true },
  }, overrides or {})
end

return {
  {
    name = "formats a provider-neutral status report",
    fn = function()
      local lines = commands.format_status(base_report({ selected_by = "auto" }))
      local text = table.concat(lines, "\n")

      h.match("ready: yes", text)
      h.match("provider: claude %(auto%)", text)
      h.match("frontend: extmark", text)
      h.match("auth: dev@example.com %(team%) via subscription", text)
      h.match("cli version: 2.1.273", text)
      h.match("session usage: 3 requests, 2 completed, 1 cancelled, 900 in / 40 out tokens", text)
      h.match("warm session: yes", text)
    end,
  },
  {
    name = "formats codex rate limits and api-key auth",
    fn = function()
      local report = base_report({
        provider = "codex",
        provider_label = "Codex",
        auth = { logged_in = true, method = "api_key", label = "api key" },
        rate_limits = { rateLimits = { primary = { remaining = 40, limit = 100 } } },
        thread = { id = "t1" },
      })
      report.usage = nil
      report.version = nil
      report.auth.plan = nil
      local lines = commands.format_status(report)
      local text = table.concat(lines, "\n")

      h.match("provider: codex\n", text)
      h.match("auth: api key via API key", text)
      h.match("rate limits: 40/100 remaining", text)
      h.match("warm session: yes", text)
    end,
  },
  {
    name = "surfaces provider setup hints",
    fn = function()
      local lines, level = commands.format_setup(base_report({
        ready = false,
        error = "Claude Code is authenticated with API-key billing; Agentify only uses subscription sessions.",
        setup_hint = "Run `claude auth login`.",
      }))
      h.eq(vim.log.levels.WARN, level)
      h.match("API%-key billing", table.concat(lines, "\n"))
      h.match("claude auth login", table.concat(lines, "\n"))

      local missing, missing_level = commands.format_setup(base_report({
        cli = { available = false, command = { "claude" } },
        setup_hint = "Install Claude Code.",
      }))
      h.eq(vim.log.levels.ERROR, missing_level)
      h.match("Claude Code CLI is not available", missing[1])
      h.eq("Install Claude Code.", missing[3])

      local ready = commands.format_setup(base_report())
      h.match("Agentify is ready %(Claude Code%)", ready[1])
    end,
  },
}
