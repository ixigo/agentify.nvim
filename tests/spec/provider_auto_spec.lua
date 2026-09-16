local auto = require("agentify.provider.auto")
local config = require("agentify.config")
local h = require("tests.helpers")

local function stub(name, ready, cli_available)
  local provider = {
    name = name,
    completed = {},
    warmed = 0,
  }

  function provider:status(callback)
    vim.schedule(function()
      callback({
        provider = name,
        ready = ready,
        cli = { available = cli_available ~= false, command = { name } },
        error = ready and nil or (name .. " not ready"),
      })
    end)
  end

  function provider:complete(ctx, callback)
    table.insert(self.completed, ctx)
    local handle = { cancelled = false }
    function handle.cancel()
      handle.cancelled = true
    end
    vim.schedule(function()
      callback({ type = "completed", text = "from " .. name })
    end)
    return handle
  end

  function provider:warmup(callback)
    self.warmed = self.warmed + 1
    callback(true, nil)
  end

  return provider
end

local function wait_for(predicate)
  return vim.wait(2000, predicate, 10)
end

return {
  {
    name = "prefers the first ready candidate",
    fn = function()
      local claude = stub("claude", true)
      local codex = stub("codex", true)
      local provider = auto.new(config.normalize({}), {
        { name = "claude", provider = claude },
        { name = "codex", provider = codex },
      })

      local result
      provider:complete({}, function(event)
        result = event
      end)

      h.ok(wait_for(function()
        return result ~= nil
      end))
      h.eq("from claude", result.text)
      h.eq("claude", provider.resolved_name)
      h.eq(0, #codex.completed)
    end,
  },
  {
    name = "falls through to the next ready candidate",
    fn = function()
      local claude = stub("claude", false)
      local codex = stub("codex", true)
      local provider = auto.new(config.normalize({}), {
        { name = "claude", provider = claude },
        { name = "codex", provider = codex },
      })

      local report
      provider:status(function(result)
        report = result
      end)

      h.ok(wait_for(function()
        return report ~= nil
      end))
      h.eq("codex", report.provider)
      h.eq("auto", report.selected_by)
      h.eq({ "claude", "codex" }, report.candidates)
    end,
  },
  {
    name = "uses the first installed CLI when nothing is ready so setup hints surface",
    fn = function()
      local claude = stub("claude", false, false)
      local codex = stub("codex", false, true)
      local provider = auto.new(config.normalize({}), {
        { name = "claude", provider = claude },
        { name = "codex", provider = codex },
      })

      local report
      provider:status(function(result)
        report = result
      end)

      h.ok(wait_for(function()
        return report ~= nil
      end))
      h.eq("codex", provider.resolved_name)
      h.match("no provider is ready", report.selection_reason)
    end,
  },
  {
    name = "honours cancel before resolution finishes",
    fn = function()
      local claude = stub("claude", true)
      local provider = auto.new(config.normalize({}), {
        { name = "claude", provider = claude },
      })

      local called = false
      local handle = provider:complete({}, function()
        called = true
      end)
      handle.cancel("test")

      vim.wait(200, function()
        return false
      end, 10)
      h.eq(false, called)
      h.eq(0, #claude.completed)
    end,
  },
  {
    name = "factory builds an auto provider by default",
    fn = function()
      local factory = require("agentify.provider")
      local provider = factory.create(config.normalize({}))
      h.eq(2, #provider.candidates)
      h.eq("claude", provider.candidates[1].name)
      h.eq("codex", provider.candidates[2].name)

      local direct = factory.create(config.normalize({ provider = "codex" }))
      h.eq(nil, direct.candidates)
    end,
  },
}
