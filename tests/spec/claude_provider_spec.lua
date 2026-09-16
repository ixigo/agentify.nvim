local claude = require("agentify.provider.claude")
local config = require("agentify.config")
local h = require("tests.helpers")

local fixtures = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures"
local fake = fixtures .. "/fake_claude.sh"

local function make_opts(overrides)
  return config.normalize(vim.tbl_deep_extend("force", {
    provider = "claude",
    providers = {
      claude = {
        command = { fake },
      },
    },
  }, overrides or {}))
end

local function make_ctx(manual)
  return {
    filepath = "/tmp/example.lua",
    filetype = "lua",
    expandtab = true,
    tabstop = 2,
    shiftwidth = 2,
    before_lines = { "local M = {}" },
    line_prefix = "function M.get() ",
    line_suffix = "",
    after_lines = {},
    manual = manual == true,
  }
end

local function collect(provider, ctx)
  local events = {}
  local handle = provider:complete(ctx, function(event)
    events[#events + 1] = event
  end)
  return events, handle
end

local function wait_for(predicate, timeout_ms)
  return vim.wait(timeout_ms or 5000, predicate, 20)
end

local function stop_all(provider)
  for _, session in pairs(provider.sessions) do
    session.transport:stop()
  end
end

return {
  {
    name = "builds a tuned claude command with the configured model",
    fn = function()
      local provider = claude.new(make_opts({ providers = { claude = { effort = "low", extra_args = { "--fallback-model", "haiku" } } } }))
      local command = provider:_build_command("haiku")

      h.eq(fake, command[1])
      h.eq("-p", command[2])
      local joined = table.concat(command, " ")
      h.match("%-%-model haiku", joined)
      h.match("%-%-tools ", joined)
      h.match("%-%-input%-format stream%-json", joined)
      h.match("%-%-output%-format stream%-json", joined)
      h.match("%-%-include%-partial%-messages", joined)
      h.match("%-%-no%-session%-persistence", joined)
      h.match("%-%-setting%-sources ", joined)
      h.match("%-%-strict%-mcp%-config", joined)
      h.match("alwaysThinkingEnabled", joined)
      h.match("%-%-effort low", joined)
      h.match("%-%-fallback%-model haiku$", joined)
      h.match("independent completion request", joined)
    end,
  },
  {
    name = "uses the manual model only for manual requests",
    fn = function()
      local provider = claude.new(make_opts())
      h.eq("haiku", provider:_model_for(make_ctx(false)))
      h.eq("sonnet", provider:_model_for(make_ctx(true)))

      local no_manual = claude.new(make_opts({ providers = { claude = { manual_model = "" } } }))
      h.eq("haiku", no_manual:_model_for(make_ctx(true)))
    end,
  },
  {
    name = "streams deltas and completes a turn through the fake CLI",
    fn = function()
      local provider = claude.new(make_opts())
      local events = collect(provider, make_ctx(false))

      h.ok(wait_for(function()
        return #events > 0 and events[#events].type == "completed"
      end), "expected a completed event, got: " .. vim.inspect(events))

      h.eq("turn_started", events[1].type)
      local saw_delta = false
      for _, event in ipairs(events) do
        if event.type == "delta" then
          saw_delta = true
        end
      end
      h.ok(saw_delta, "expected at least one delta event")
      h.eq("return value", events[#events].text)
      h.eq(1, provider.usage.completed)
      h.eq(1, provider.usage.requests)
      h.eq(12, provider.usage.input_tokens + provider.usage.output_tokens)
      h.ok(provider.sessions.haiku.initialized, "session should be initialized")

      stop_all(provider)
    end,
  },
  {
    name = "treats an interrupted turn as cancelled, not as an error",
    fn = function()
      vim.env.FAKE_CLAUDE_MODE = "hang"
      local provider = claude.new(make_opts())
      local events, handle = collect(provider, make_ctx(false))

      h.ok(wait_for(function()
        return #events >= 2
      end), "expected turn_started and a delta before cancelling")

      handle.cancel("cursor-moved")

      h.ok(wait_for(function()
        return provider.usage.cancelled == 1
      end), "expected the interrupted result to be counted as cancelled")

      for _, event in ipairs(events) do
        h.ok(event.type ~= "error", "cancelled turn must not surface an error event")
        h.ok(event.type ~= "completed", "cancelled turn must not surface a completed event")
      end
      h.eq(0, #provider.sessions.haiku.inflight)

      vim.env.FAKE_CLAUDE_MODE = nil
      stop_all(provider)
    end,
  },
  {
    name = "recycles the session after max_session_turns",
    fn = function()
      local provider = claude.new(make_opts({ providers = { claude = { max_session_turns = 1 } } }))
      local events = collect(provider, make_ctx(false))
      local first_pid = provider.sessions.haiku.transport:get_status().pid

      h.ok(wait_for(function()
        return #events > 0 and events[#events].type == "completed"
      end))
      h.ok(wait_for(function()
        local status = provider.sessions.haiku.transport:get_status()
        return status.running and status.pid ~= first_pid
      end), "expected a fresh process after recycling")
      h.eq(0, provider.sessions.haiku.turns)

      stop_all(provider)
    end,
  },
  {
    name = "reports ready for a subscription login",
    fn = function()
      local provider = claude.new(make_opts())
      local report
      provider:status(function(result)
        report = result
      end)

      h.ok(wait_for(function()
        return report ~= nil
      end))
      h.eq(true, report.ready, vim.inspect(report))
      h.eq("claude", report.provider)
      h.eq("2.1.273", report.version)
      h.eq("subscription", report.auth.method)
      h.eq("dev@example.com", report.auth.label)
      h.eq("team", report.auth.plan)
    end,
  },
  {
    name = "refuses API-key billing when subscription_only is set",
    fn = function()
      vim.env.FAKE_CLAUDE_AUTH = "apikey"
      local provider = claude.new(make_opts())
      local report
      provider:status(function(result)
        report = result
      end)

      h.ok(wait_for(function()
        return report ~= nil
      end))
      h.eq(false, report.ready)
      h.eq("api_key", report.auth.method)
      h.match("subscription", report.error)
      h.match("claude auth login", report.setup_hint)

      local permissive = claude.new(make_opts({ auth = { subscription_only = false } }))
      local permissive_report
      permissive:status(function(result)
        permissive_report = result
      end)
      h.ok(wait_for(function()
        return permissive_report ~= nil
      end))
      h.eq(true, permissive_report.ready)

      vim.env.FAKE_CLAUDE_AUTH = nil
    end,
  },
  {
    name = "reports a login hint when signed out",
    fn = function()
      vim.env.FAKE_CLAUDE_AUTH = "loggedout"
      local provider = claude.new(make_opts())
      local report
      provider:status(function(result)
        report = result
      end)

      h.ok(wait_for(function()
        return report ~= nil
      end))
      h.eq(false, report.ready)
      h.eq(false, report.auth.logged_in)
      h.match("claude auth login", report.setup_hint)

      vim.env.FAKE_CLAUDE_AUTH = nil
    end,
  },
  {
    name = "parses auth status JSON with leading noise",
    fn = function()
      local auth = claude.parse_auth_status('Warning: something\n{"loggedIn":true,"authMethod":"claude.ai","email":"a@b.c","subscriptionType":"max"}')
      h.eq(true, auth.logged_in)
      h.eq("subscription", auth.method)
      h.eq("max", auth.plan)
      h.eq(nil, claude.parse_auth_status("not json"))
    end,
  },
}
