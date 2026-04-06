local M = {}

local levels = {
  error = 0,
  warn = 1,
  info = 2,
  debug = 3,
}

local state = {
  level = "warn",
  max_entries = 200,
  entries = {},
}

local function normalize_level(level)
  if levels[level] == nil then
    error(("agentify.nvim: invalid logging.level %q"):format(tostring(level)))
  end

  return level
end

local function should_record(level)
  return levels[level] <= levels[state.level]
end

local function push(level, message, data)
  if not should_record(level) then
    return
  end

  table.insert(state.entries, {
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    level = level,
    message = message,
    data = data,
  })

  while #state.entries > state.max_entries do
    table.remove(state.entries, 1)
  end
end

function M.configure(opts)
  state.level = normalize_level(opts.level or state.level)
  state.max_entries = opts.max_entries or state.max_entries
end

function M.error(message, data)
  push("error", message, data)
end

function M.warn(message, data)
  push("warn", message, data)
end

function M.info(message, data)
  push("info", message, data)
end

function M.debug(message, data)
  push("debug", message, data)
end

function M.entries()
  return vim.deepcopy(state.entries)
end

function M.clear()
  state.entries = {}
end

return M

