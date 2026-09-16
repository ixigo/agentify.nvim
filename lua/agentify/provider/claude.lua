-- Claude Code provider: drives the local `claude` CLI as a warm streaming process.
--
-- One process per model. Requests are written as stream-json user messages and answered
-- with stream_event deltas followed by a result line. Cancellation sends a control_request
-- interrupt; the interrupted turn ends with a result of subtype error_during_execution,
-- which is treated as "cancelled", not as an error.
local env_util = require("agentify.transport.env")
local log = require("agentify.log")
local ndjson = require("agentify.transport.ndjson")
local prompt = require("agentify.provider.prompt")

local M = {}
local ClaudeProvider = {}
ClaudeProvider.__index = ClaudeProvider

local function command_available(command)
  if command:find("/", 1, true) then
    local stat = (vim.uv or vim.loop).fs_stat(command)
    return stat ~= nil
  end

  return vim.fn.executable(command) == 1
end

local function is_rate_limit_text(text)
  if type(text) ~= "string" then
    return false
  end

  local lowered = text:lower()
  return lowered:find("rate limit", 1, true) ~= nil
    or lowered:find("usage limit", 1, true) ~= nil
    or lowered:find("429", 1, true) ~= nil
end

function ClaudeProvider.new(opts)
  local self = setmetatable({
    opts = opts,
    popts = opts.providers.claude,
    sessions = {},
    next_turn = 1,
    next_control = 1,
    last_error = nil,
    version = nil,
    auth = nil,
    usage = {
      requests = 0,
      completed = 0,
      cancelled = 0,
      failed = 0,
      input_tokens = 0,
      output_tokens = 0,
    },
  }, ClaudeProvider)

  return self
end

function ClaudeProvider:_check_cli()
  if command_available(self.popts.command[1]) then
    return true
  end

  return false, ("claude CLI not found: %s"):format(table.concat(self.popts.command, " "))
end

function ClaudeProvider:_model_for(context)
  if context and context.manual and self.popts.manual_model and self.popts.manual_model ~= "" then
    return self.popts.manual_model
  end

  return self.popts.model
end

function ClaudeProvider:_build_command(model)
  local command = vim.deepcopy(self.popts.command)
  local args = {
    "-p",
    "--model", model,
    "--tools", "",
    "--disable-slash-commands",
    "--no-session-persistence",
    "--input-format", "stream-json",
    "--output-format", "stream-json",
    "--include-partial-messages",
    "--verbose",
    "--system-prompt", prompt.base_instructions(self.opts, self.popts),
    "--setting-sources", "",
    "--strict-mcp-config",
    "--mcp-config", '{"mcpServers":{}}',
    "--settings", '{"alwaysThinkingEnabled":false}',
  }

  if self.popts.effort and self.popts.effort ~= "" then
    table.insert(args, "--effort")
    table.insert(args, self.popts.effort)
  end

  for _, extra in ipairs(self.popts.extra_args or {}) do
    table.insert(args, extra)
  end

  vim.list_extend(command, args)
  return command
end

function ClaudeProvider:_session(model)
  local session = self.sessions[model]
  if session then
    return session
  end

  session = {
    model = model,
    transport = ndjson.new({
      command = self:_build_command(model),
      env_blocklist = self.opts.auth.strip_env,
      label = ("claude (%s)"):format(model),
    }),
    inflight = {},
    turns = 0,
    initialized = false,
  }

  session.transport:on_line(function(message)
    self:_handle_message(session, message)
  end)

  session.transport:on_exit(function(_, err)
    self:_handle_exit(session, err)
  end)

  self.sessions[model] = session
  return session
end

function ClaudeProvider:_ensure_session(model, callback)
  local ok, err = self:_check_cli()
  if not ok then
    self.last_error = err
    callback(nil, err)
    return
  end

  local session = self:_session(model)
  local started, start_err = session.transport:start()
  if not started then
    self.last_error = start_err
    callback(nil, start_err)
    return
  end

  callback(session, nil)
end

function ClaudeProvider:_interrupt(session)
  local request_id = ("agentify-%d"):format(self.next_control)
  self.next_control = self.next_control + 1

  local ok, err = session.transport:write({
    type = "control_request",
    request_id = request_id,
    request = { subtype = "interrupt" },
  })

  if not ok then
    log.debug("failed to send claude interrupt", { error = err })
  end
end

function ClaudeProvider:_record_usage(message)
  local usage = message.usage or {}
  self.usage.input_tokens = self.usage.input_tokens
    + (usage.input_tokens or 0)
    + (usage.cache_creation_input_tokens or 0)
    + (usage.cache_read_input_tokens or 0)
  self.usage.output_tokens = self.usage.output_tokens + (usage.output_tokens or 0)
end

function ClaudeProvider:_maybe_recycle(session)
  if #session.inflight > 0 or session.turns < self.popts.max_session_turns then
    return
  end

  log.debug("recycling claude session", { model = session.model, turns = session.turns })
  session.transport:stop()
  session.turns = 0
  session.initialized = false
  -- Respawn immediately so the next request does not pay the boot cost.
  session.transport:start()
end

function ClaudeProvider:_handle_message(session, message)
  local kind = message.type

  if kind == "system" then
    if message.subtype == "init" then
      session.initialized = true
      session.transport:mark_initialized()
      log.debug("claude session initialized", { model = message.model })
    end
    return
  end

  if kind == "stream_event" then
    local pending = session.inflight[1]
    if not pending then
      return
    end

    local event = message.event or {}
    if event.type == "content_block_delta" and event.delta and event.delta.type == "text_delta" then
      pending.text = pending.text .. (event.delta.text or "")
      if not pending.handle.cancelled then
        pending.callback({
          type = "delta",
          text = pending.text,
          turn_id = pending.turn_id,
        })
      end
    end
    return
  end

  if kind == "assistant" then
    -- Full assistant message; used as a fallback when partial deltas were not delivered.
    local pending = session.inflight[1]
    if not pending or pending.text ~= "" then
      return
    end

    local content = message.message and message.message.content or {}
    local parts = {}
    for _, item in ipairs(content) do
      if item.type == "text" and item.text then
        parts[#parts + 1] = item.text
      end
    end
    pending.text = table.concat(parts, "")
    return
  end

  if kind == "result" then
    local pending = table.remove(session.inflight, 1)
    session.turns = session.turns + 1
    self:_record_usage(message)

    if not pending then
      self:_maybe_recycle(session)
      return
    end

    if pending.handle.cancelled or pending.interrupt_sent then
      self.usage.cancelled = self.usage.cancelled + 1
      log.debug("claude turn cancelled", { turn_id = pending.turn_id, subtype = message.subtype })
      self:_maybe_recycle(session)
      return
    end

    if message.subtype == "success" or message.is_error == false then
      self.usage.completed = self.usage.completed + 1
      pending.callback({
        type = "completed",
        text = (type(message.result) == "string" and message.result ~= "") and message.result or pending.text,
        turn_id = pending.turn_id,
        usage = message.usage,
      })
    else
      self.usage.failed = self.usage.failed + 1
      local err = type(message.result) == "string" and message.result ~= "" and message.result
        or ("claude turn ended with %s"):format(tostring(message.subtype))
      if is_rate_limit_text(err) then
        self.rate_limited_at = os.time()
      end
      self.last_error = err
      pending.callback({
        type = "error",
        error = err,
      })
    end

    self:_maybe_recycle(session)
    return
  end

  if kind == "control_response" then
    log.debug("claude control response", { response = message.response and message.response.subtype })
    return
  end

  if kind == "error" or (kind == "result" and message.is_error) then
    self.last_error = message.error or message.result or "claude reported an error"
  end
end

function ClaudeProvider:_handle_exit(session, err)
  session.initialized = false
  session.turns = 0
  self.last_error = err

  local inflight = session.inflight
  session.inflight = {}

  for _, pending in ipairs(inflight) do
    if not pending.handle.cancelled then
      self.usage.failed = self.usage.failed + 1
      pending.callback({
        type = "error",
        error = err or "claude process exited",
      })
    end
  end
end

function ClaudeProvider:complete(context, callback)
  local handle = {
    cancelled = false,
    turn_id = nil,
  }

  function handle.cancel(reason)
    if handle.cancelled then
      return
    end

    handle.cancelled = true
    handle.cancel_reason = reason or "cancelled"

    local pending = handle.pending
    if pending and handle.session and not pending.interrupt_sent then
      pending.interrupt_sent = true
      self:_interrupt(handle.session)
    end
  end

  local model = self:_model_for(context)

  self:_ensure_session(model, function(session, err)
    if err then
      callback({ type = "error", error = err })
      return
    end

    if handle.cancelled then
      return
    end

    -- Serialize: anything still in flight on this session is superseded.
    for _, previous in ipairs(session.inflight) do
      if not previous.interrupt_sent then
        previous.handle.cancelled = true
        previous.interrupt_sent = true
        self:_interrupt(session)
      end
    end

    local turn_id = ("claude-%d"):format(self.next_turn)
    self.next_turn = self.next_turn + 1

    local pending = {
      handle = handle,
      callback = callback,
      text = "",
      turn_id = turn_id,
      interrupt_sent = false,
    }

    handle.turn_id = turn_id
    handle.pending = pending
    handle.session = session
    table.insert(session.inflight, pending)

    local ok, write_err = session.transport:write({
      type = "user",
      message = {
        role = "user",
        content = {
          { type = "text", text = prompt.build_completion_request(context, self.opts) },
        },
      },
    })

    if not ok then
      for index, item in ipairs(session.inflight) do
        if item == pending then
          table.remove(session.inflight, index)
          break
        end
      end
      self.last_error = write_err
      callback({ type = "error", error = write_err })
      return
    end

    self.usage.requests = self.usage.requests + 1
    log.debug("claude turn started", { turn_id = turn_id, model = model, filetype = context.filetype })

    callback({
      type = "turn_started",
      turn_id = turn_id,
    })
  end)

  return handle
end

function ClaudeProvider:warmup(callback)
  self:_ensure_session(self.popts.model, function(_, err)
    if callback then
      callback(err == nil, err)
    end
  end)
end

function ClaudeProvider:_run_cli(args, callback)
  local command = vim.deepcopy(self.popts.command)
  vim.list_extend(command, args)

  local env = env_util.build_map(self.opts.auth.strip_env)
  local ok, err = pcall(vim.system, command, {
    text = true,
    env = env,
    clear_env = true,
    timeout = 15000,
  }, function(result)
    vim.schedule(function()
      callback(result.stdout or "", result.code, result.stderr or "")
    end)
  end)

  if not ok then
    vim.schedule(function()
      callback("", -1, tostring(err))
    end)
  end
end

local function parse_version(text)
  return (text or ""):match("(%d+%.%d+%.%d+)")
end

local function version_ok(actual, minimum)
  if not actual then
    return false
  end

  local ok_actual, parsed = pcall(vim.version.parse, actual)
  local ok_min, parsed_min = pcall(vim.version.parse, minimum)
  if not ok_actual or not ok_min or not parsed or not parsed_min then
    return true
  end

  return not vim.version.lt(parsed, parsed_min)
end

function M.parse_auth_status(text)
  local trimmed = vim.trim(text or "")
  local start = trimmed:find("{", 1, true)
  if not start then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, trimmed:sub(start))
  if not ok or type(decoded) ~= "table" then
    return nil
  end

  local logged_in = decoded.loggedIn == true
  local method
  if logged_in then
    if decoded.authMethod == "claude.ai" then
      method = "subscription"
    else
      method = "api_key"
    end
  end

  return {
    logged_in = logged_in,
    method = method,
    label = decoded.email or decoded.authMethod or (logged_in and "signed in" or "signed out"),
    plan = decoded.subscriptionType,
    raw_method = decoded.authMethod,
    provider = decoded.apiProvider,
  }
end

function ClaudeProvider:status(callback)
  local session = self.sessions[self.popts.model]
  local report = {
    provider = "claude",
    provider_label = "Claude Code",
    cli = {
      available = command_available(self.popts.command[1]),
      command = vim.deepcopy(self.popts.command),
    },
    transport = session and session.transport:get_status() or { running = false, initialized = false },
    thread = {
      warm = session ~= nil and session.transport:is_running(),
      model = self.popts.model,
    },
    auth = self.auth,
    usage = vim.deepcopy(self.usage),
    version = self.version,
    error = self.last_error,
    setup_hint = nil,
    ready = false,
  }

  if not report.cli.available then
    report.error = ("claude CLI not found: %s"):format(table.concat(self.popts.command, " "))
    report.setup_hint = "Install Claude Code (`npm install -g @anthropic-ai/claude-code` or the native installer), then restart Neovim."
    callback(report)
    return
  end

  -- `--version` and `auth status` each cost a CLI boot (~3s); run them concurrently.
  local version_out, auth_out
  local remaining = 2

  local function finish()
    remaining = remaining - 1
    if remaining > 0 then
      return
    end

    self.version = parse_version(version_out)
    report.version = self.version

    do
      local auth = M.parse_auth_status(auth_out)
      self.auth = auth
      report.auth = auth

      if not auth then
        report.error = "could not read `claude auth status` output"
        report.setup_hint = "Run `claude auth status` in a terminal and make sure it prints JSON."
        callback(report)
        return
      end

      if not auth.logged_in then
        report.error = "Claude Code CLI is not authenticated."
        report.setup_hint = "Run `claude auth login` and sign in with your claude.ai account, then re-run `:AgentifyStatus`."
        callback(report)
        return
      end

      if self.opts.auth.subscription_only and auth.method ~= "subscription" then
        report.error = "Claude Code is authenticated with API-key billing; Agentify only uses subscription sessions."
        report.setup_hint = "Run `claude auth login` to use your claude.ai subscription (hour-based limits), or set `auth.subscription_only = false` to allow API-key billing."
        callback(report)
        return
      end

      if not version_ok(self.version, self.popts.min_version) then
        report.error = ("claude %s is older than the required %s."):format(tostring(self.version), self.popts.min_version)
        report.setup_hint = "Run `claude update` and restart Neovim."
        callback(report)
        return
      end

      report.ready = true
      report.error = nil
      if session then
        report.transport = session.transport:get_status()
        report.thread.warm = session.transport:is_running()
      end
      callback(report)
    end
  end

  self:_run_cli({ "--version" }, function(out)
    version_out = out
    finish()
  end)

  self:_run_cli({ "auth", "status" }, function(out)
    auth_out = out
    finish()
  end)
end

function M.new(opts)
  return ClaudeProvider.new(opts)
end

return M
