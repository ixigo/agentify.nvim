local M = {}

local function notify(lines, level)
  vim.notify(table.concat(lines, "\n"), level or vim.log.levels.INFO, {
    title = "agentify.nvim",
  })
end

local function provider_label(report)
  return report.provider_label or report.provider or "provider"
end

local function render_rate_limits(report)
  if not report.rate_limits or not report.rate_limits.rateLimits then
    return nil
  end

  local primary = report.rate_limits.rateLimits.primary
  if not primary then
    return "available"
  end

  return ("%s/%s remaining"):format(tostring(primary.remaining), tostring(primary.limit))
end

local function render_usage(report)
  local usage = report.usage
  if not usage then
    return nil
  end

  return ("%d requests, %d completed, %d cancelled, %d in / %d out tokens"):format(
    usage.requests or 0,
    usage.completed or 0,
    usage.cancelled or 0,
    usage.input_tokens or 0,
    usage.output_tokens or 0
  )
end

local function render_auth(report)
  local auth = report.auth
  if not auth then
    return "unknown"
  end

  if not auth.logged_in then
    return "not signed in"
  end

  local label = auth.label or "signed in"
  if auth.plan then
    label = ("%s (%s)"):format(label, auth.plan)
  end

  if auth.method == "subscription" then
    return label .. " via subscription"
  elseif auth.method == "api_key" then
    return label .. " via API key"
  end

  return label
end

function M.format_status(report)
  local provider = report.provider or "none"
  if report.selected_by == "auto" then
    provider = provider .. " (auto)"
  end

  local transport = report.transport or {}
  local lines = {
    ("ready: %s"):format(report.ready and "yes" or "no"),
    ("provider: %s"):format(provider),
    ("frontend: %s"):format(report.frontend or "extmark"),
    ("buffer: %s (%s)"):format(
      report.buffer.filetype ~= "" and report.buffer.filetype or "none",
      report.buffer.enabled and "enabled" or report.buffer.reason
    ),
    ("transport: %s"):format(transport.running and "running" or "stopped"),
    ("initialized: %s"):format(transport.initialized and "yes" or "no"),
    ("auth: %s"):format(render_auth(report)),
  }

  if report.version then
    table.insert(lines, ("cli version: %s"):format(report.version))
  end

  local limits = render_rate_limits(report)
  if limits then
    table.insert(lines, ("rate limits: %s"):format(limits))
  end

  local usage = render_usage(report)
  if usage then
    table.insert(lines, ("session usage: %s"):format(usage))
  end

  local thread = report.thread or {}
  table.insert(lines, ("warm session: %s"):format((thread.warm or thread.id) and "yes" or "no"))

  if report.error then
    table.insert(lines, ("error: %s"):format(report.error))
  end

  if report.suggestion then
    table.insert(lines, ("active suggestion: %q"):format(report.suggestion.text))
  end

  return lines
end

function M.format_setup(report)
  local label = provider_label(report)

  if not report.cli or not report.cli.available then
    return {
      ("%s CLI is not available."):format(label),
      ("Expected command: %s"):format(table.concat(report.cli and report.cli.command or {}, " ")),
      report.setup_hint or ("Install the %s CLI, then restart Neovim."):format(label),
    }, vim.log.levels.ERROR
  end

  if report.auth and not report.auth.logged_in then
    return {
      ("%s CLI is installed but not authenticated."):format(label),
      report.setup_hint or "Sign in with the CLI, then re-run `:AgentifyStatus`.",
    }, vim.log.levels.WARN
  end

  if report.error then
    local lines = {
      "Agentify is not ready yet.",
      report.error,
    }
    if report.setup_hint then
      table.insert(lines, report.setup_hint)
    end
    table.insert(lines, "Run `:AgentifyStatus` after fixing the issue above.")
    return lines, vim.log.levels.WARN
  end

  return {
    ("Agentify is ready (%s)."):format(label),
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
