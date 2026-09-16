-- Repo-aware context from the local Agentify structural index.
--
-- For identifiers near the cursor, asks `agentify query def/refs --json` for the
-- definition and a few call sites, reads those lines from disk (or the open buffer), and
-- hands them to the prompt. Results are cached per root+symbol; lookups run in the
-- background and the request proceeds without them after `timeout_ms`.
local log = require("agentify.log")

local uv = vim.uv or vim.loop

local M = {
  cache = {},
  root_cache = {},
  stats = { lookups = 0, hits = 0, misses = 0, timeouts = 0, errors = 0 },
}

local KEYWORDS = {}
for _, word in ipairs({
  "and", "async", "await", "bool", "break", "case", "catch", "class", "const", "continue", "def",
  "default", "do", "elif", "else", "end", "except", "export", "false", "finally", "fn", "for",
  "from", "func", "function", "if", "import", "in", "int", "interface", "let", "local", "new",
  "nil", "not", "null", "number", "of", "or", "private", "public", "return", "self", "static",
  "string", "struct", "switch", "then", "this", "true", "try", "type", "undefined", "var", "void",
  "while", "with", "yield", "console", "print", "println",
}) do
  KEYWORDS[word] = true
end

local function now()
  return os.time()
end

local function dirname(path)
  return vim.fn.fnamemodify(path, ":h")
end

-- Finds the nearest ancestor directory containing .agentify/index.db.
function M.find_root(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local dir = vim.fn.isdirectory(path) == 1 and path or dirname(path)
  local start = dir
  local visited = {}

  while dir and dir ~= "" and not visited[dir] do
    if M.root_cache[dir] ~= nil then
      local cached = M.root_cache[dir]
      M.root_cache[start] = cached
      return cached or nil
    end

    visited[dir] = true
    if uv.fs_stat(dir .. "/.agentify/index.db") then
      M.root_cache[start] = dir
      return dir
    end

    local parent = dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end

  M.root_cache[start] = false
  return nil
end

-- Identifiers worth looking up: callees (followed by "(") first, then other identifiers,
-- each rightmost first. The token still being typed is skipped.
function M.candidate_symbols(ctx, opts)
  local prefix = ctx.line_prefix or ""
  local skip_partial = prefix:match("[%w_]$") ~= nil
  local defined = ctx.intent and ctx.intent.symbol_name or nil

  local tokens = {}
  for start, identifier, finish in prefix:gmatch("()([%a_][%w_]*)()") do
    tokens[#tokens + 1] = {
      name = identifier,
      is_call = prefix:sub(finish):match("^%s*%(") ~= nil,
      start = start,
    }
  end

  if skip_partial and #tokens > 0 then
    table.remove(tokens, #tokens)
  end

  local seen = {}
  local result = {}
  local function take(want_call)
    for index = #tokens, 1, -1 do
      local token = tokens[index]
      if token.is_call == want_call
        and #token.name >= opts.min_symbol_chars
        and not KEYWORDS[token.name:lower()]
        and token.name ~= defined
        and not seen[token.name]
      then
        seen[token.name] = true
        result[#result + 1] = token.name
        if #result >= opts.max_symbols then
          return true
        end
      end
    end
    return false
  end

  if not take(true) then
    take(false)
  end

  return result
end

local function read_lines(root, relative, first, last)
  local absolute = root .. "/" .. relative
  local bufnr = vim.fn.bufnr(absolute)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  end

  local ok, lines = pcall(vim.fn.readfile, absolute, "", last)
  if not ok or type(lines) ~= "table" then
    return {}
  end

  local slice = {}
  for index = first, math.min(last, #lines) do
    slice[#slice + 1] = lines[index]
  end
  return slice
end

local function run_query(opts, root, subcommand, symbol, callback)
  local command = vim.deepcopy(opts.command)
  vim.list_extend(command, { "query", subcommand, "--symbol", symbol, "--json", "--root", root })

  local ok, err = pcall(vim.system, command, { text = true, timeout = opts.process_timeout_ms }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, (result.stderr or ""):gsub("%s+$", ""))
        return
      end

      local stdout = result.stdout or ""
      local start = stdout:find("{", 1, true)
      if not start then
        callback(nil, "no json in agentify output")
        return
      end

      local decoded_ok, decoded = pcall(vim.json.decode, stdout:sub(start))
      if not decoded_ok or type(decoded) ~= "table" then
        callback(nil, "could not decode agentify output")
        return
      end

      callback(decoded, nil)
    end)
  end)

  if not ok then
    vim.schedule(function()
      callback(nil, tostring(err))
    end)
  end
end

local function build_entry(opts, root, symbol, current_relative, def_result, refs_result)
  local entry = { name = symbol, definition = nil, references = {} }

  local definition = def_result and def_result.definitions and def_result.definitions[1] or nil
  if definition and definition.file_path and definition.start_line then
    local last = math.min(definition.end_line or definition.start_line, definition.start_line + opts.max_definition_lines - 1)
    entry.definition = {
      file = definition.file_path,
      start_line = definition.start_line,
      kind = definition.kind,
      lines = read_lines(root, definition.file_path, definition.start_line, last),
    }
  end

  local refs = refs_result and (refs_result.references or refs_result.callers) or {}
  local calls, others = {}, {}
  for _, ref in ipairs(refs) do
    if ref.file_path ~= current_relative and not (entry.definition and ref.file_path == entry.definition.file and ref.line == entry.definition.start_line) then
      if ref.kind == "call" then
        calls[#calls + 1] = ref
      else
        others[#others + 1] = ref
      end
    end
  end

  for _, ref in ipairs(vim.list_extend(calls, others)) do
    if #entry.references >= opts.max_reference_lines then
      break
    end
    local text = read_lines(root, ref.file_path, ref.line, ref.line)[1]
    if text and text:match("%S") then
      entry.references[#entry.references + 1] = {
        file = ref.file_path,
        line = ref.line,
        text = vim.trim(text),
      }
    end
  end

  if not entry.definition and #entry.references == 0 then
    return nil
  end

  return entry
end

local function cache_key(root, symbol)
  return root .. "\0" .. symbol
end

local function cache_get(key, ttl)
  local hit = M.cache[key]
  if not hit then
    return nil, false
  end

  if now() - hit.at > ttl then
    M.cache[key] = nil
    return nil, false
  end

  return hit.entry, true
end

local function cache_put(key, entry, max_entries)
  M.cache[key] = { entry = entry, at = now() }

  local count = 0
  local oldest_key, oldest_at
  for existing_key, item in pairs(M.cache) do
    count = count + 1
    if not oldest_at or item.at < oldest_at then
      oldest_key, oldest_at = existing_key, item.at
    end
  end
  if count > max_entries and oldest_key then
    M.cache[oldest_key] = nil
  end
end

-- Looks up one symbol (def + refs) and caches the outcome, including "nothing found".
function M.lookup(opts, root, symbol, current_relative, callback)
  local key = cache_key(root, symbol)
  local entry, hit = cache_get(key, opts.cache_ttl_s)
  if hit then
    M.stats.hits = M.stats.hits + 1
    callback(entry)
    return true
  end

  M.stats.lookups = M.stats.lookups + 1
  local pending = M.inflight and M.inflight[key]
  if pending then
    table.insert(pending, callback)
    return false
  end

  M.inflight = M.inflight or {}
  M.inflight[key] = { callback }

  local def_result, refs_result
  local remaining = 2
  local function finish()
    remaining = remaining - 1
    if remaining > 0 then
      return
    end

    local built = build_entry(opts, root, symbol, current_relative, def_result, refs_result)
    if built then
      M.stats.misses = M.stats.misses + 1
    end
    cache_put(key, built, opts.max_cache_entries)

    local waiters = M.inflight[key] or {}
    M.inflight[key] = nil
    for _, waiter in ipairs(waiters) do
      waiter(built)
    end
  end

  run_query(opts, root, "def", symbol, function(result, err)
    if err then
      M.stats.errors = M.stats.errors + 1
      log.debug("agentify def query failed", { symbol = symbol, error = err })
    end
    def_result = result
    finish()
  end)

  run_query(opts, root, "refs", symbol, function(result, err)
    if err then
      log.debug("agentify refs query failed", { symbol = symbol, error = err })
    end
    refs_result = result
    finish()
  end)

  return false
end

-- Collects repo context for `ctx` and calls `callback(repo_or_nil)`.
-- Calls back synchronously when disabled, when no index is present, or when every
-- symbol is cached; otherwise waits up to `timeout_ms` for the lookups.
function M.collect(ctx, opts, callback)
  local popts = opts.repo_context
  if not popts.enabled or vim.fn.executable(popts.command[1]) ~= 1 then
    callback(nil)
    return
  end

  local root = M.find_root(ctx.filepath)
  if not root then
    callback(nil)
    return
  end

  local symbols = M.candidate_symbols(ctx, popts)
  if #symbols == 0 then
    callback(nil)
    return
  end

  local current_relative = ctx.filepath:sub(#root + 2)
  local results = {}
  local pending = 0
  local finished = false
  local timer

  local function deliver()
    if finished then
      return
    end
    finished = true
    if timer then
      timer:stop()
      timer:close()
    end

    local ordered = {}
    for _, symbol in ipairs(symbols) do
      if results[symbol] then
        ordered[#ordered + 1] = results[symbol]
      end
    end

    callback(#ordered > 0 and { root = root, symbols = ordered } or nil)
  end

  for _, symbol in ipairs(symbols) do
    local sync = M.lookup(popts, root, symbol, current_relative, function(entry)
      results[symbol] = entry
      pending = pending - 1
      if pending <= 0 then
        deliver()
      end
    end)
    if not sync then
      pending = pending + 1
    end
  end

  if pending <= 0 then
    deliver()
    return
  end

  timer = uv.new_timer()
  timer:start(popts.timeout_ms, 0, vim.schedule_wrap(function()
    if not finished then
      M.stats.timeouts = M.stats.timeouts + 1
      log.debug("repo context lookup timed out; continuing without it", { symbols = symbols })
      deliver()
    end
  end))
end

function M.status(opts, bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr or 0)
  local root = path ~= "" and M.find_root(path) or M.find_root(uv.cwd())
  local count = 0
  for _ in pairs(M.cache) do
    count = count + 1
  end

  return {
    enabled = opts.repo_context.enabled,
    cli_available = vim.fn.executable(opts.repo_context.command[1]) == 1,
    root = root,
    cache_entries = count,
    stats = vim.deepcopy(M.stats),
  }
end

function M.reset()
  M.cache = {}
  M.root_cache = {}
  M.inflight = {}
  M.stats = { lookups = 0, hits = 0, misses = 0, timeouts = 0, errors = 0 }
end

return M
