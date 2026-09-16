-- Picks the first authenticated provider from a preference list and delegates to it.
-- Resolution happens once, on the first warmup/complete/status call.
local log = require("agentify.log")

local M = {}
local AutoProvider = {}
AutoProvider.__index = AutoProvider

function AutoProvider.new(opts, candidates)
  return setmetatable({
    opts = opts,
    candidates = candidates,
    resolved = nil,
    resolved_name = nil,
    resolution_reason = nil,
    resolving = false,
    waiters = {},
  }, AutoProvider)
end

function AutoProvider:_finish(candidate, reason)
  self.resolved = candidate.provider
  self.resolved_name = candidate.name
  self.resolution_reason = reason
  self.resolving = false

  log.info("auto provider selected", { provider = candidate.name, reason = reason })

  local waiters = self.waiters
  self.waiters = {}
  for _, waiter in ipairs(waiters) do
    waiter(self.resolved)
  end
end

function AutoProvider:_resolve(callback)
  if self.resolved then
    callback(self.resolved)
    return
  end

  table.insert(self.waiters, callback)
  if self.resolving then
    return
  end

  self.resolving = true

  local index = 0
  local fallback = nil

  local function try_next()
    index = index + 1
    local candidate = self.candidates[index]

    if not candidate then
      local chosen = fallback or self.candidates[1]
      self:_finish(chosen, fallback and "no provider is ready; using first installed CLI" or "no provider CLI found")
      return
    end

    candidate.provider:status(function(report)
      if report.ready then
        self:_finish(candidate, "authenticated and ready")
        return
      end

      if report.cli and report.cli.available and not fallback then
        fallback = candidate
      end

      log.debug("auto provider skipped candidate", { provider = candidate.name, error = report.error })
      try_next()
    end)
  end

  try_next()
end

function AutoProvider:complete(context, callback)
  local handle = {
    cancelled = false,
    inner = nil,
  }

  function handle.cancel(reason)
    if handle.cancelled then
      return
    end

    handle.cancelled = true
    if handle.inner and handle.inner.cancel then
      handle.inner.cancel(reason)
    end
  end

  self:_resolve(function(provider)
    if handle.cancelled then
      return
    end

    handle.inner = provider:complete(context, callback)
    handle.turn_id = handle.inner and handle.inner.turn_id or nil
  end)

  return handle
end

function AutoProvider:warmup(callback)
  self:_resolve(function(provider)
    if provider.warmup then
      provider:warmup(callback)
    elseif callback then
      callback(true, nil)
    end
  end)
end

function AutoProvider:status(callback)
  local names = {}
  for _, candidate in ipairs(self.candidates) do
    names[#names + 1] = candidate.name
  end

  self:_resolve(function(provider)
    provider:status(function(report)
      report.selected_by = "auto"
      report.selection_reason = self.resolution_reason
      report.candidates = names
      callback(report)
    end)
  end)
end

function M.new(opts, candidates)
  return AutoProvider.new(opts, candidates)
end

return M
