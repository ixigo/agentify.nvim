local budget = require("agentify.budget")
local config = require("agentify.config")
local context = require("agentify.context")
local engine = require("agentify.engine")
local h = require("tests.helpers")
local intent = require("agentify.intent")
local state = require("agentify.state")

local function fake_provider()
  local provider = { calls = 0, last_callback = nil }
  function provider.complete(_, _, callback)
    provider.calls = provider.calls + 1
    provider.last_callback = callback
    return { cancel = function() end }
  end
  function provider.status(_, callback)
    callback({ provider = "fake", cli = { available = false, command = { "fake" } }, transport = {}, thread = {} })
  end
  function provider.warmup(_, callback)
    if callback then
      callback(true, nil)
    end
  end
  return provider
end

local function with_engine(lines, fn, overrides)
  local original_get_mode = vim.api.nvim_get_mode
  vim.api.nvim_get_mode = function()
    return { mode = "i", blocking = false }
  end

  local provider = fake_provider()
  state.reset()
  engine.setup(config.normalize(vim.tbl_deep_extend("force", { budget = { notify = false } }, overrides or {})), provider)

  local ok, err = pcall(h.with_buffer, lines, function(bufnr)
    vim.bo[bufnr].filetype = "lua"
    vim.cmd("startinsert")
    return fn(bufnr, provider)
  end)

  vim.api.nvim_get_mode = original_get_mode
  if not ok then
    error(err, 0)
  end
end

local function make_budget(overrides)
  return budget.new(config.normalize({ budget = overrides or {} }))
end

return {
  {
    name = "counts requests in a sliding hour and enforces the cap",
    fn = function()
      local b = make_budget({ max_requests_per_hour = 2 })
      local now = 1000

      h.eq(true, (b:allow(now, false)))
      b:record(now)
      h.eq(true, (b:allow(now + 10, false)))
      b:record(now + 10)

      local ok, reason = b:allow(now + 20, false)
      h.eq(false, ok)
      h.eq("budget", reason)
      h.eq(2, b:used(now + 20))
      h.eq(3600 - 20, b:resets_in(now + 20))

      -- the oldest stamp falls out of the window, the newer one stays
      h.eq(true, (b:allow(now + 3601, false)))
      h.eq(1, b:used(now + 3601))

      -- manual requests bypass the cap
      b:record(now + 3601)
      h.eq(false, (b:allow(now + 3602, false)))
      h.eq(true, (b:allow(now + 3602, true)))
    end,
  },
  {
    name = "zero cap disables the limit and fast_only blocks automatic requests",
    fn = function()
      local unlimited = make_budget({ max_requests_per_hour = 0 })
      for index = 1, 50 do
        h.eq(true, (unlimited:allow(index, false)))
        unlimited:record(index)
      end

      local fast_only = make_budget({ fast_only = true })
      local ok, reason = fast_only:allow(1, false)
      h.eq(false, ok)
      h.eq("fast_only", reason)
      h.eq(true, (fast_only:allow(1, true)))
    end,
  },
  {
    name = "a cooldown blocks everything, including manual requests, until it expires",
    fn = function()
      local b = make_budget({})
      b:pause(300, "rate_limit", 1000)

      local ok, reason = b:allow(1100, true)
      h.eq(false, ok)
      h.eq("cooldown", reason)
      h.eq(200, b:report(1100).paused_for)
      h.eq("rate_limit", b:report(1100).pause_reason)

      h.eq(true, (b:allow(1300, false)))
      h.eq(nil, b.paused_until)

      b:pause(300, "rate_limit", 2000)
      b:record(2000)
      b:resume(true)
      h.eq(true, (b:allow(2001, false)))
      h.eq(0, b:used(2001))
    end,
  },
  {
    name = "announces each pause reason once until the tier is allowed again",
    fn = function()
      local b = make_budget({ max_requests_per_hour = 1 })
      b:record(10)
      b:allow(11, false)
      h.eq(true, b:should_announce("budget"))
      h.eq(false, b:should_announce("budget"))
      h.eq(true, (b:allow(3700, false)))
      h.eq(true, b:should_announce("budget"))
    end,
  },
  {
    name = "recognises rate limit errors and formats durations",
    fn = function()
      h.eq(true, budget.is_rate_limit("API Error: 429 Too Many Requests"))
      h.eq(true, budget.is_rate_limit("You have hit your usage limit"))
      h.eq(true, budget.is_rate_limit("rate_limit_error"))
      h.eq(false, budget.is_rate_limit("codex thread/start returned no thread id"))
      h.eq(false, budget.is_rate_limit(nil))

      h.eq("45s", budget.format_duration(45))
      h.eq("5m", budget.format_duration(300))
      h.eq("3m", budget.format_duration(121))
      h.eq("1h 5m", budget.format_duration(3900))
    end,
  },
  {
    name = "denies sensitive paths and keeps ordinary files enabled",
    fn = function()
      local opts = config.normalize({})
      for _, path in ipairs({
        "/repo/.env",
        "/repo/.env.local",
        "/repo/config/secrets/db.json",
        "/home/dev/.ssh/id_rsa",
        "/home/dev/.aws/credentials",
        "/repo/certs/server.pem",
        "/repo/Server.KEY",
      }) do
        h.eq(true, (config.path_denied(opts, path)), "expected deny for " .. path)
      end

      for _, path in ipairs({ "/repo/src/app.lua", "/repo/environment.ts", "/repo/keyboard.lua", "" }) do
        h.eq(false, (config.path_denied(opts, path)), "expected allow for " .. path)
      end

      local custom = config.normalize({ paths = { deny = { "/vendor/" } } })
      h.eq(true, (config.path_denied(custom, "/repo/vendor/lib.lua")))
      h.eq(false, (config.path_denied(custom, "/repo/.env")))
    end,
  },
  {
    name = "a denied buffer is not eligible for suggestions",
    fn = function()
      local opts = config.normalize({})
      h.with_buffer({ "SECRET=1" }, function(bufnr)
        vim.api.nvim_buf_set_name(bufnr, "/tmp/agentify-test/.env")
        vim.bo[bufnr].filetype = "sh"
        local enabled, reason = config.is_buffer_enabled(opts, bufnr)
        h.eq(false, enabled)
        h.match("paths.deny", reason)
      end)
    end,
  },
  {
    name = "denied buffers are excluded from related context",
    fn = function()
      local peer = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(peer, "/tmp/agentify-test/secrets/tokens.ts")
      vim.api.nvim_buf_set_lines(peer, 0, -1, false, {
        "export function joinArray(array: string[]) {",
        '  return array.join(", ");',
        "}",
      })
      vim.bo[peer].filetype = "typescript"

      local ok, err = xpcall(function()
        h.with_buffer({ "const convertArrayToString = (items) =>" }, function(bufnr)
          vim.bo[bufnr].filetype = "typescript"
          vim.cmd("startinsert")
          vim.api.nvim_win_set_cursor(0, { 1, #"const convertArrayToString = (items) =>" })

          local opts = config.normalize({})
          local ctx = context.build(bufnr, opts)
          local analysed = intent.analyze(bufnr, ctx, opts)
          local related = table.concat(analysed and analysed.related_lines or {}, "\n")
          h.ok(not related:find("joinArray", 1, true), "denied peer leaked into related lines: " .. related)

          local permissive = config.normalize({ paths = { deny = {} } })
          local ctx2 = context.build(bufnr, permissive)
          local analysed2 = intent.analyze(bufnr, ctx2, permissive)
          local related2 = table.concat(analysed2 and analysed2.related_lines or {}, "\n")
          h.ok(related2:find("joinArray", 1, true) ~= nil, "peer should be used when not denied")
        end)
      end, debug.traceback)

      if vim.api.nvim_buf_is_valid(peer) then
        vim.api.nvim_buf_delete(peer, { force = true })
      end
      if not ok then
        error(err, 0)
      end
    end,
  },
  {
    name = "engine stops calling the provider once the hourly cap is hit",
    fn = function()
      with_engine({ "local alpha = beta" }, function(bufnr, provider)
        vim.api.nvim_win_set_cursor(0, { 1, #"local alpha = beta" })

        local ok = engine.request(bufnr, { manual = false })
        h.eq(true, ok)
        h.eq(1, provider.calls)

        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "local alpha = gamma" })
        vim.api.nvim_win_set_cursor(0, { 1, #"local alpha = gamma" })
        local ok2, reason = engine.request(bufnr, { manual = false })
        h.eq(false, ok2)
        h.match("provider skipped: budget", reason)
        h.eq(1, provider.calls)
        h.eq(1, engine.budget.stats.skipped_budget)

        -- manual requests still reach the model
        engine.request(bufnr, { manual = true })
        h.eq(2, provider.calls)

        engine.reset_budget()
        engine.request(bufnr, { manual = false })
        h.eq(3, provider.calls)

        local report = engine.budget:report()
        h.eq(1, report.limit)
        h.eq(3, report.stats.provider)
      end, { budget = { max_requests_per_hour = 1 } })
    end,
  },
  {
    name = "a rate-limit error from the provider pauses the model tier",
    fn = function()
      with_engine({ "local alpha = beta" }, function(bufnr, provider)
        vim.api.nvim_win_set_cursor(0, { 1, #"local alpha = beta" })
        engine.request(bufnr, { manual = false })
        h.eq(1, provider.calls)

        provider.last_callback({ type = "error", error = "API Error: 429 rate limit reached" })
        vim.wait(200, function()
          return engine.budget.paused_until ~= nil
        end, 10)
        h.eq("rate_limit", engine.budget.pause_reason)

        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "local alpha = gamma" })
        vim.api.nvim_win_set_cursor(0, { 1, #"local alpha = gamma" })
        local ok, reason = engine.request(bufnr, { manual = true })
        h.eq(false, ok)
        h.match("cooldown", reason)
        h.eq(1, provider.calls)

        local report = engine.budget:report()
        h.ok(report.paused_for > 0 and report.paused_for <= 300)
      end, { budget = { rate_limit_cooldown_s = 300 } })
    end,
  },
  {
    name = "status output renders budget and tier counters",
    fn = function()
      local commands = require("agentify.commands")
      local lines = commands.format_status({
        provider = "claude",
        ready = true,
        cli = { available = true, command = { "claude" } },
        transport = { running = true, initialized = true },
        thread = { warm = true },
        buffer = { filetype = "lua", enabled = true },
        budget = {
          used = 12,
          limit = 300,
          resets_in = 2900,
          paused_for = 120,
          pause_reason = "rate_limit",
          stats = { fast = 40, recall = 5, type_through = 9, provider = 12, skipped_budget = 0, skipped_cooldown = 2 },
        },
      })
      local text = table.concat(lines, "\n")
      h.match("model budget: 12/300 requests this hour %(window resets in 49m%)", text)
      h.match("model tier paused: rate limit, resumes in 2m", text)
      h.match("answered by: fast 40, recall 5, type%-through 9, model 12, skipped 2", text)
    end,
  },
}
