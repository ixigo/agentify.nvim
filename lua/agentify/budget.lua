-- Guards the model tier against burning through an hour-based subscription window.
--
-- Tracks provider requests in a sliding one-hour window, pauses the model tier after a
-- rate-limit error, and keeps per-session counters of which tier answered so the
-- fast-tier thresholds can be tuned with data.
local M = {}
local Budget = {}
Budget.__index = Budget

M.WINDOW_SECONDS = 3600

function Budget.new(opts)
  return setmetatable({
    opts = opts.budget,
    stamps = {},
    paused_until = nil,
    pause_reason = nil,
    announced = nil,
    stats = {
      fast = 0,
      recall = 0,
      type_through = 0,
      provider = 0,
      skipped_budget = 0,
      skipped_cooldown = 0,
      skipped_fast_only = 0,
    },
  }, Budget)
end

function Budget:_prune(now)
  local cutoff = now - M.WINDOW_SECONDS
  while self.stamps[1] and self.stamps[1] <= cutoff do
    table.remove(self.stamps, 1)
  end
end

function Budget:used(now)
  self:_prune(now or os.time())
  return #self.stamps
end

function Budget:limit()
  return self.opts.max_requests_per_hour
end

-- Returns whether a provider request may start, and otherwise why not:
-- "cooldown" (rate limited), "fast_only", or "budget" (hourly cap reached).
-- Manual requests bypass the cap and fast_only, but never a cooldown.
function Budget:allow(now, manual)
  now = now or os.time()

  if self.paused_until then
    if now < self.paused_until then
      return false, "cooldown"
    end
    self.paused_until = nil
    self.pause_reason = nil
    self.announced = nil
  end

  if manual then
    return true, nil
  end

  if self.opts.fast_only then
    return false, "fast_only"
  end

  local limit = self:limit()
  if limit > 0 and self:used(now) >= limit then
    return false, "budget"
  end

  self.announced = nil
  return true, nil
end

function Budget:record(now)
  table.insert(self.stamps, now or os.time())
  self.stats.provider = self.stats.provider + 1
end

function Budget:skip(reason)
  local key = "skipped_" .. reason
  self.stats[key] = (self.stats[key] or 0) + 1
end

function Budget:count(kind)
  self.stats[kind] = (self.stats[kind] or 0) + 1
end

function Budget:pause(seconds, reason, now)
  now = now or os.time()
  self.paused_until = now + seconds
  self.pause_reason = reason
  self.announced = nil
end

-- Lifts a pause and, when `clear_window` is set, forgets the hourly request history.
function Budget:resume(clear_window)
  self.paused_until = nil
  self.pause_reason = nil
  self.announced = nil
  if clear_window then
    self.stamps = {}
  end
end

function Budget:resets_in(now)
  now = now or os.time()
  self:_prune(now)
  if not self.stamps[1] then
    return 0
  end
  return math.max(0, self.stamps[1] + M.WINDOW_SECONDS - now)
end

-- Marks `reason` as announced; returns true the first time only.
function Budget:should_announce(reason)
  if self.announced == reason then
    return false
  end
  self.announced = reason
  return true
end

function Budget:report(now)
  now = now or os.time()
  return {
    used = self:used(now),
    limit = self:limit(),
    resets_in = self:resets_in(now),
    fast_only = self.opts.fast_only,
    paused_until = self.paused_until,
    paused_for = self.paused_until and math.max(0, self.paused_until - now) or nil,
    pause_reason = self.pause_reason,
    stats = vim.deepcopy(self.stats),
  }
end

function M.is_rate_limit(text)
  if type(text) ~= "string" then
    return false
  end

  local lowered = text:lower()
  return lowered:find("rate limit", 1, true) ~= nil
    or lowered:find("rate_limit", 1, true) ~= nil
    or lowered:find("usage limit", 1, true) ~= nil
    or lowered:find("too many requests", 1, true) ~= nil
    or lowered:find("429", 1, true) ~= nil
end

function M.format_duration(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  if seconds >= 3600 then
    return ("%dh %dm"):format(math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
  end
  if seconds >= 60 then
    return ("%dm"):format(math.ceil(seconds / 60))
  end
  return ("%ds"):format(seconds)
end

M.new = Budget.new

return M
