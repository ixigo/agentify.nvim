local env_util = require("agentify.transport.env")
local log = require("agentify.log")

local uv = vim.uv or vim.loop

local M = {}
local StdioTransport = {}
StdioTransport.__index = StdioTransport

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

function StdioTransport.new(opts)
  local self = setmetatable({
    command = vim.deepcopy(opts.command),
    env_blocklist = opts.env_blocklist,
    label = opts.label or "codex app-server",
    client_info = {
      name = opts.client_name or "agentify.nvim",
      version = opts.client_version or "0.1.0",
    },
    handle = nil,
    stdin = nil,
    stdout = nil,
    stderr = nil,
    stdout_buffer = "",
    stderr_buffer = "",
    next_id = 1,
    pending = {},
    notification_listeners = {},
    exit_listener = nil,
    start_waiters = {},
    starting = false,
    status = {
      command = table.concat(opts.command, " "),
      running = false,
      initialized = false,
      pid = nil,
      last_error = nil,
      last_exit = nil,
      stderr_tail = "",
    },
  }, StdioTransport)

  return self
end

function StdioTransport:get_status()
  return vim.deepcopy(self.status)
end

function StdioTransport:on_notification(callback)
  table.insert(self.notification_listeners, callback)
end

function StdioTransport:on_exit(callback)
  self.exit_listener = callback
end

function StdioTransport:is_running()
  return self.status.running and self.status.initialized
end

function StdioTransport:_append_stderr(chunk)
  self.stderr_buffer = (self.stderr_buffer .. chunk):sub(-4000)
  self.status.stderr_tail = self.stderr_buffer
end

function StdioTransport:_finish_start(ok, err)
  local waiters = self.start_waiters
  self.start_waiters = {}

  for _, waiter in ipairs(waiters) do
    schedule(waiter, ok, err)
  end
end

function StdioTransport:_emit_notification(message)
  for _, listener in ipairs(self.notification_listeners) do
    schedule(listener, message)
  end
end

function StdioTransport:_fail_pending(err)
  for id, callback in pairs(self.pending) do
    self.pending[id] = nil
    schedule(callback, nil, err)
  end
end

function StdioTransport:_reset_handles()
  close_handle(self.stdin)
  close_handle(self.stdout)
  close_handle(self.stderr)

  self.stdin = nil
  self.stdout = nil
  self.stderr = nil
  self.handle = nil
end

function StdioTransport:_handle_exit(code, signal)
  self.status.running = false
  self.status.initialized = false
  self.status.last_exit = {
    code = code,
    signal = signal,
  }

  if not self.status.last_error then
    self.status.last_error = ("%s exited with code %s"):format(self.label, tostring(code))
  end

  self:_reset_handles()
  self:_fail_pending(self.status.last_error)
  self:_finish_start(false, self.status.last_error)

  if self.exit_listener then
    schedule(self.exit_listener, self.status.last_exit, self.status.last_error)
  end
end

function StdioTransport:_handle_response(message)
  local callback = self.pending[message.id]
  if not callback then
    return
  end

  self.pending[message.id] = nil

  if message.error then
    local err = message.error.message or vim.inspect(message.error)
    self.status.last_error = err
    log.debug("app-server request failed", { id = message.id, error = err })
    schedule(callback, nil, err)
    return
  end

  log.debug("app-server request completed", { id = message.id })
  schedule(callback, message, nil)
end

function StdioTransport:_handle_message(line)
  local ok, message = pcall(vim.json.decode, line)
  if not ok then
    log.warn("failed to decode app-server message", { line = line })
    return
  end

  if message.id ~= nil then
    self:_handle_response(message)
  else
    self:_emit_notification(message)
  end
end

function StdioTransport:_write(payload)
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

function StdioTransport:_send_raw_request(method, params, callback)
  local request_id = self.next_id
  self.next_id = self.next_id + 1

  local payload = {
    jsonrpc = "2.0",
    id = request_id,
    method = method,
  }

  if params ~= nil then
    payload.params = params
  end

  self.pending[request_id] = callback
  log.debug("app-server request sent", { id = request_id, method = method })

  local ok, err = self:_write(payload)
  if not ok then
    self.pending[request_id] = nil
    schedule(callback, nil, err)
  end
end

function StdioTransport:notify(method, params)
  local payload = {
    jsonrpc = "2.0",
    method = method,
  }

  if params ~= nil then
    payload.params = params
  end

  return self:_write(payload)
end

function StdioTransport:start(callback)
  if self:is_running() then
    schedule(callback, true, nil)
    return
  end

  table.insert(self.start_waiters, callback)

  if self.starting then
    return
  end

  self.starting = true
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
    stdio = { self.stdin, self.stdout, self.stderr },
  }, function(code, signal)
    schedule(function()
      self.starting = false
      self:_handle_exit(code, signal)
    end)
  end)

  if not handle then
    self.starting = false
    self.status.last_error = ("failed to spawn %s"):format(table.concat(self.command, " "))
    self:_reset_handles()
    self:_finish_start(false, self.status.last_error)
    return
  end

  self.handle = handle
  self.status.running = true
  self.status.pid = pid

  uv.read_start(self.stdout, function(err, chunk)
    if err then
      self.status.last_error = err
      return
    end

    if not chunk then
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
        self:_handle_message(line)
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

  self:_send_raw_request("initialize", {
    clientInfo = self.client_info,
    capabilities = nil,
  }, function(response, err)
    self.starting = false

    if err then
      self.status.last_error = err
      self:_reset_handles()
      self.status.running = false
      self:_finish_start(false, err)
      return
    end

    self.status.initialized = true
    self.status.last_error = nil
    self:notify("initialized", {})
    self:_finish_start(true, nil)
    log.debug("initialized codex app-server transport", response and response.result or nil)
  end)
end

function StdioTransport:ensure_ready(callback)
  if self:is_running() then
    schedule(callback, true, nil)
    return
  end

  self:start(callback)
end

function StdioTransport:request(method, params, callback)
  self:ensure_ready(function(ok, err)
    if not ok then
      callback(nil, err)
      return
    end

    self:_send_raw_request(method, params, callback)
  end)
end

function StdioTransport:stop()
  if self.handle and not self.handle:is_closing() then
    pcall(self.handle.kill, self.handle, "sigterm")
  end

  self:_reset_handles()
  self.status.running = false
  self.status.initialized = false
end

M.new = StdioTransport.new

return M
