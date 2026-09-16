-- Line-oriented JSON transport for `claude -p --input-format stream-json --output-format stream-json`.
-- Unlike the Codex JSON-RPC transport there is no handshake and no request ids: the
-- provider correlates turns by order.
local env_util = require("agentify.transport.env")
local log = require("agentify.log")

local uv = vim.uv or vim.loop

local M = {}
local NdjsonTransport = {}
NdjsonTransport.__index = NdjsonTransport

local function schedule(callback, ...)
  local args = { ... }
  vim.schedule(function()
    callback(unpack(args))
  end)
end

local function close_handle(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

function NdjsonTransport.new(opts)
  local self = setmetatable({
    command = vim.deepcopy(opts.command),
    env_blocklist = opts.env_blocklist,
    cwd = opts.cwd,
    label = opts.label or "claude",
    handle = nil,
    stdin = nil,
    stdout = nil,
    stderr = nil,
    stdout_buffer = "",
    stderr_buffer = "",
    line_listeners = {},
    exit_listener = nil,
    status = {
      command = table.concat(opts.command, " "),
      running = false,
      initialized = false,
      pid = nil,
      started_at = nil,
      last_error = nil,
      last_exit = nil,
      stderr_tail = "",
    },
  }, NdjsonTransport)

  return self
end

function NdjsonTransport:get_status()
  return vim.deepcopy(self.status)
end

function NdjsonTransport:on_line(callback)
  table.insert(self.line_listeners, callback)
end

function NdjsonTransport:on_exit(callback)
  self.exit_listener = callback
end

function NdjsonTransport:is_running()
  return self.status.running
end

function NdjsonTransport:mark_initialized()
  self.status.initialized = true
end

function NdjsonTransport:_append_stderr(chunk)
  self.stderr_buffer = (self.stderr_buffer .. chunk):sub(-4000)
  self.status.stderr_tail = self.stderr_buffer
end

function NdjsonTransport:_reset_handles()
  close_handle(self.stdin)
  close_handle(self.stdout)
  close_handle(self.stderr)

  self.stdin = nil
  self.stdout = nil
  self.stderr = nil
  self.handle = nil
end

-- The process exit callback can fire before the final stdout chunks are read. Exit is
-- therefore recorded here and handled once stdout reaches EOF (or after a short grace).
function NdjsonTransport:_note_exit(code, signal)
  self.exit_pending = { code = code, signal = signal }
  if self.stdout_eof or not self.stdout then
    self:_flush_exit()
    return
  end

  local timer = uv.new_timer()
  timer:start(500, 0, function()
    timer:stop()
    timer:close()
    schedule(function()
      self:_flush_exit()
    end)
  end)
end

function NdjsonTransport:_flush_exit()
  local pending = self.exit_pending
  if not pending then
    return
  end
  self.exit_pending = nil
  self:_handle_exit(pending.code, pending.signal)
end

function NdjsonTransport:_handle_exit(code, signal)
  local was_running = self.status.running
  self.status.running = false
  self.status.initialized = false
  self.status.last_exit = { code = code, signal = signal }

  if not self.status.last_error then
    self.status.last_error = ("%s exited with code %s"):format(self.label, tostring(code))
  end

  self:_reset_handles()

  if self.exit_listener and was_running then
    schedule(self.exit_listener, self.status.last_exit, self.status.last_error)
  end
end

function NdjsonTransport:_handle_line(line)
  local ok, message = pcall(vim.json.decode, line)
  if not ok or type(message) ~= "table" then
    log.debug("ignoring non-json line from " .. self.label, { line = line:sub(1, 200) })
    return
  end

  for _, listener in ipairs(self.line_listeners) do
    schedule(listener, message)
  end
end

function NdjsonTransport:write(payload)
  if not self.stdin or self.stdin:is_closing() then
    return false, ("%s stdin is unavailable"):format(self.label)
  end

  local ok, err = pcall(self.stdin.write, self.stdin, vim.json.encode(payload) .. "\n")
  if not ok then
    self.status.last_error = err
    return false, err
  end

  return true
end

function NdjsonTransport:start()
  if self:is_running() then
    return true
  end

  self.stdout_buffer = ""
  self.stderr_buffer = ""
  self.status.last_error = nil
  self.status.stderr_tail = ""

  self.stdin = uv.new_pipe(false)
  self.stdout = uv.new_pipe(false)
  self.stderr = uv.new_pipe(false)

  local command = self.command[1]
  local args = {}
  for index = 2, #self.command do
    table.insert(args, self.command[index])
  end

  local handle, pid = uv.spawn(command, {
    args = args,
    env = env_util.build(self.env_blocklist),
    cwd = self.cwd,
    stdio = { self.stdin, self.stdout, self.stderr },
  }, function(code, signal)
    schedule(function()
      self:_note_exit(code, signal)
    end)
  end)

  if not handle then
    self.status.last_error = ("failed to spawn %s"):format(table.concat(self.command, " "))
    self:_reset_handles()
    return false, self.status.last_error
  end

  self.handle = handle
  self.status.running = true
  self.status.pid = pid
  self.status.started_at = os.time()
  self.stdout_eof = false
  self.exit_pending = nil

  uv.read_start(self.stdout, function(err, chunk)
    if err then
      self.status.last_error = err
      return
    end

    if not chunk then
      -- EOF: deliver any unterminated final line, then let a pending exit through.
      local rest = vim.trim(self.stdout_buffer)
      self.stdout_buffer = ""
      if rest ~= "" then
        self:_handle_line(rest)
      end
      self.stdout_eof = true
      schedule(function()
        self:_flush_exit()
      end)
      return
    end

    self.stdout_buffer = self.stdout_buffer .. chunk

    while true do
      local newline = self.stdout_buffer:find("\n", 1, true)
      if not newline then
        break
      end

      local line = vim.trim(self.stdout_buffer:sub(1, newline - 1))
      self.stdout_buffer = self.stdout_buffer:sub(newline + 1)

      if line ~= "" then
        self:_handle_line(line)
      end
    end
  end)

  uv.read_start(self.stderr, function(err, chunk)
    if err then
      self.status.last_error = err
      return
    end

    if chunk then
      self:_append_stderr(chunk)
    end
  end)

  log.debug("spawned " .. self.label, { pid = pid, command = self.status.command })

  return true
end

-- Closes the child's stdin. One-shot `claude -p <prompt>` runs otherwise wait ~3s for
-- piped input before starting.
function NdjsonTransport:close_stdin()
  if self.stdin and not self.stdin:is_closing() then
    pcall(self.stdin.shutdown, self.stdin, function()
      close_handle(self.stdin)
      self.stdin = nil
    end)
  end
end

function NdjsonTransport:stop()
  local was_running = self.status.running
  self.status.running = false
  self.status.initialized = false

  if self.stdin and not self.stdin:is_closing() then
    pcall(self.stdin.shutdown, self.stdin)
  end

  if self.handle and not self.handle:is_closing() then
    pcall(self.handle.kill, self.handle, "sigterm")
  end

  self:_reset_handles()

  return was_running
end

M.new = NdjsonTransport.new

return M
