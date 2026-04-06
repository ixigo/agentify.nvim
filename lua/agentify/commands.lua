local M = {}

local function notify(lines, level)
  vim.notify(table.concat(lines, "\n"), level or vim.log.levels.INFO, {
    title = "agentify.nvim",
  })
end

local function render_rate_limits(report)
  if not report.rate_limits or not report.rate_limits.rateLimits then
    return "unknown"
  end

  local primary = report.rate_limits.rateLimits.primary
  if not primary then
    return "available"
  end

  return ("%s/%s remaining"):format(tostring(primary.remaining), tostring(primary.limit))
end

function M.format_status(report)
  local lines = {
    ("ready: %s"):format(report.ready and "yes" or "no"),
    ("provider: %s"):format(report.provider),
    ("buffer: %s (%s)"):format(report.buffer.filetype ~= "" and report.buffer.filetype or "none", report.buffer.enabled and "enabled" or report.buffer.reason),
    ("transport: %s"):format(report.transport.running and "running" or "stopped"),
    ("initialized: %s"):format(report.transport.initialized and "yes" or "no"),
  }

  if report.account and report.account.account then
    if report.account.account.type == "chatgpt" then
      table.insert(lines, ("account: %s (%s)"):format(report.account.account.email, report.account.account.planType))
    else
      table.insert(lines, "account: api key")
    end
  else
    table.insert(lines, "account: unavailable")
  end

  table.insert(lines, ("rate limits: %s"):format(render_rate_limits(report)))
  table.insert(lines, ("warm thread: %s"):format(report.thread.id and "yes" or "no"))

  if report.error then
    table.insert(lines, ("error: %s"):format(report.error))
  end

  if report.suggestion then
    table.insert(lines, ("active suggestion: %q"):format(report.suggestion.text))
  end

  return lines
end

function M.format_setup(report)
  if not report.cli.available then
    return {
      "Codex CLI is not available.",
      ("Expected command: %s"):format(table.concat(report.cli.command, " ")),
      "Install Codex CLI, then restart Neovim.",
    }, vim.log.levels.ERROR
  end

  if report.account and report.account.account == nil and report.account.requiresOpenaiAuth then
    return {
      "Codex CLI is installed but not authenticated.",
      "Run `codex login` in a terminal.",
      "Then re-run `:AgentifyStatus`.",
    }, vim.log.levels.WARN
  end

  if report.error then
    return {
      "Agentify is not ready yet.",
      report.error,
      "Run `:AgentifyStatus` after fixing the issue above.",
    }, vim.log.levels.WARN
  end

  return {
    "Agentify is ready.",
    "Use `:AgentifySuggest` to request a suggestion manually.",
    "Map `require('agentify').accept()` and `require('agentify').accept_word()` for insert-mode acceptance.",
  }, vim.log.levels.INFO
end

function M.setup(api)
  for _, name in ipairs({ "AgentifyStatus", "AgentifySetup", "AgentifySuggest" }) do
    pcall(vim.api.nvim_del_user_command, name)
  end

  vim.api.nvim_create_user_command("AgentifyStatus", function()
    api.status(function(report)
      notify(M.format_status(report))
    end)
  end, {})

  vim.api.nvim_create_user_command("AgentifySetup", function()
    api.status(function(report)
      local lines, level = M.format_setup(report)
      notify(lines, level)
    end)
  end, {})

  vim.api.nvim_create_user_command("AgentifySuggest", function()
    api.suggest()
  end, {})
end

return M
