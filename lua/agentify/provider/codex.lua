local log = require("agentify.log")
local prompt = require("agentify.provider.prompt")
local stdio = require("agentify.transport.stdio")

local M = {}
local CodexProvider = {}
CodexProvider.__index = CodexProvider

local function command_available(command)
  if command:find("/", 1, true) then
    local stat = (vim.uv or vim.loop).fs_stat(command)
    return stat ~= nil
  end

  return vim.fn.executable(command) == 1
end

function CodexProvider.new(opts)
  local self = setmetatable({
    opts = opts,
    popts = opts.providers.codex,
    transport = stdio.new({
      command = opts.providers.codex.command,
      env_blocklist = opts.auth.strip_env,
      label = "codex app-server",
      client_name = "agentify.nvim",
      client_version = "0.2.0",
    }),
    thread_id = nil,
    account = nil,
    rate_limits = nil,
    last_error = nil,
    pending_turns = {},
  }, CodexProvider)

  self.transport:on_notification(function(message)
    self:_handle_notification(message)
  end)

  self.transport:on_exit(function(_, err)
    self.thread_id = nil
    self.last_error = err

    for turn_id, pending in pairs(self.pending_turns) do
      self.pending_turns[turn_id] = nil
      if not pending.handle.cancelled then
        pending.callback({
          type = "error",
          error = err,
        })
      end
    end
  end)

  return self
end

function CodexProvider:_check_cli()
  if command_available(self.popts.command[1]) then
    return true
  end

  return false, ("codex CLI not found: %s"):format(table.concat(self.popts.command, " "))
end

function CodexProvider:_interrupt_turn(turn_id)
  if not self.thread_id or not self.transport:is_running() then
    return
  end

  self.transport:request("turn/interrupt", {
    threadId = self.thread_id,
    turnId = turn_id,
  }, function(_, err)
    if err then
      log.debug("failed to interrupt codex turn", { turn_id = turn_id, error = err })
    end
  end)
end

function CodexProvider:_ensure_transport(callback)
  local ok, err = self:_check_cli()
  if not ok then
    self.last_error = err
    callback(false, err)
    return
  end

  self.transport:ensure_ready(function(ready, transport_err)
    if not ready then
      self.last_error = transport_err
      callback(false, transport_err)
      return
    end

    callback(true, nil)
  end)
end

function CodexProvider:_ensure_thread(callback)
  if self.thread_id and self.transport:is_running() then
    callback(self.thread_id, nil)
    return
  end

  self:_ensure_transport(function(ok, err)
    if not ok then
      callback(nil, err)
      return
    end

    local params = {
      cwd = (vim.uv or vim.loop).cwd(),
      approvalPolicy = "never",
      sandbox = "read-only",
      ephemeral = true,
      experimentalRawEvents = false,
      persistExtendedHistory = false,
      baseInstructions = prompt.base_instructions(self.opts, self.popts),
      serviceName = "agentify.nvim",
    }

    if self.popts.model then
      params.model = self.popts.model
    end

    if self.popts.service_tier then
      params.serviceTier = self.popts.service_tier
    end

    self.transport:request("thread/start", params, function(response, request_err)
      if request_err then
        self.last_error = request_err
        callback(nil, request_err)
        return
      end

      local thread = response.result and response.result.thread or nil
      if not thread or not thread.id then
        self.last_error = "codex thread/start returned no thread id"
        callback(nil, self.last_error)
        return
      end

      self.thread_id = thread.id
      log.debug("created warm codex thread", { thread_id = self.thread_id })
      callback(self.thread_id, nil)
    end)
  end)
end

function CodexProvider:_handle_notification(message)
  local method = message.method
  local params = message.params or {}
  local data = { method = method }
  if params.item and params.item.type then
    data.item_type = params.item.type
  end
  log.debug("codex notification", data)

  if method == "item/agentMessage/delta" then
    local pending = self.pending_turns[params.turnId]
    if not pending or pending.handle.cancelled then
      return
    end

    pending.text = pending.text .. (params.delta or "")
    pending.callback({
      type = "delta",
      text = pending.text,
      turn_id = params.turnId,
    })
    return
  end

  if method == "turn/completed" then
    local turn = params.turn or {}
    local pending = self.pending_turns[turn.id]
    if not pending then
      return
    end

    self.pending_turns[turn.id] = nil

    if pending.handle.cancelled or turn.status == "interrupted" then
      return
    end

    if turn.status == "failed" then
      local err = turn.error and turn.error.message or "codex turn failed"
      self.last_error = err
      pending.callback({
        type = "error",
        error = err,
        turn = turn,
      })
      return
    end

    pending.callback({
      type = "completed",
      text = pending.text,
      turn_id = turn.id,
      turn = turn,
    })
    return
  end

  if method == "item/completed" then
    local item = params.item or {}
    if item.type ~= "agentMessage" then
      return
    end

    local pending = self.pending_turns[params.turnId]
    if not pending then
      return
    end

    self.pending_turns[params.turnId] = nil

    if pending.handle.cancelled then
      return
    end

    pending.callback({
      type = "completed",
      text = item.text or pending.text,
      turn_id = params.turnId,
      item = item,
    })
    return
  end

  if method == "error" then
    local err = params.error and params.error.message or "codex app-server reported an error"
    self.last_error = err

    local pending = self.pending_turns[params.turnId]
    if pending then
      self.pending_turns[params.turnId] = nil
      if not pending.handle.cancelled then
        pending.callback({
          type = "error",
          error = err,
        })
      end
    end
    return
  end

  if method == "account/rateLimits/updated" then
    self.rate_limits = {
      rateLimits = params.rateLimits,
    }
  end
end

function CodexProvider:complete(context, callback)
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
    if handle.turn_id then
      self:_interrupt_turn(handle.turn_id)
    end
  end

  self:_ensure_thread(function(thread_id, err)
    if err then
      callback({
        type = "error",
        error = err,
      })
      return
    end

    if handle.cancelled then
      return
    end

    local params = {
      threadId = thread_id,
      approvalPolicy = "never",
      effort = self.popts.effort,
      summary = "none",
      input = {
        {
          type = "text",
          text = prompt.build_completion_request(context, self.opts),
          text_elements = {},
        },
      },
    }

    if self.popts.model then
      params.model = self.popts.model
    end

    if self.popts.service_tier then
      params.serviceTier = self.popts.service_tier
    end

    log.debug("starting codex completion turn", {
      thread_id = thread_id,
      filetype = context.filetype,
      filepath = context.filepath,
    })
    self.transport:request("turn/start", params, function(response, request_err)
      if request_err then
        self.last_error = request_err
        callback({
          type = "error",
          error = request_err,
        })
        return
      end

      local turn = response.result and response.result.turn or nil
      if not turn or not turn.id then
        local err_message = "codex turn/start returned no turn id"
        self.last_error = err_message
        callback({
          type = "error",
          error = err_message,
        })
        return
      end

      handle.turn_id = turn.id
      self.pending_turns[turn.id] = {
        callback = callback,
        handle = handle,
        text = "",
      }
      log.debug("codex turn started", { turn_id = turn.id })

      callback({
        type = "turn_started",
        turn_id = turn.id,
      })

      if handle.cancelled then
        self:_interrupt_turn(turn.id)
      end
    end)
  end)

  return handle
end

function CodexProvider:warmup(callback)
  self:_ensure_thread(function(_, err)
    if callback then
      callback(err == nil, err)
    end
  end)
end

function CodexProvider:status(callback)
  local report = {
    provider = "codex",
    provider_label = "Codex",
    cli = {
      available = command_available(self.popts.command[1]),
      command = vim.deepcopy(self.popts.command),
    },
    transport = self.transport:get_status(),
    thread = {
      id = self.thread_id,
      warm = self.thread_id ~= nil,
    },
    account = self.account,
    rate_limits = self.rate_limits,
    error = self.last_error,
    ready = false,
  }

  if not report.cli.available then
    report.error = ("codex CLI not found: %s"):format(table.concat(self.popts.command, " "))
    report.setup_hint = "Install the Codex CLI, then restart Neovim."
    callback(report)
    return
  end

  self:_ensure_transport(function(ok, err)
    report.transport = self.transport:get_status()

    if not ok then
      report.error = err
      callback(report)
      return
    end

    self.transport:request("account/read", {
      refreshToken = self.popts.refresh_account_token,
    }, function(account_response, account_err)
      if account_err then
        report.error = account_err
        report.transport = self.transport:get_status()
        callback(report)
        return
      end

      self.account = account_response.result
      report.account = self.account

      self.transport:request("account/rateLimits/read", nil, function(rate_response, rate_err)
        if not rate_err and rate_response then
          self.rate_limits = rate_response.result
        end

        report.rate_limits = self.rate_limits
        report.transport = self.transport:get_status()
        report.thread = {
          id = self.thread_id,
          warm = self.thread_id ~= nil,
        }
        report.error = rate_err or self.last_error

        local account = report.account and report.account.account or nil
        local requires_auth = report.account and report.account.requiresOpenaiAuth
        local needs_login = account == nil and requires_auth
        report.auth = M.normalize_account(account)
        report.ready = account ~= nil and report.transport.initialized

        if report.ready and not rate_err then
          report.error = nil
        elseif not report.ready and not report.error and needs_login then
          report.error = "Codex CLI is not authenticated."
          report.setup_hint = "Run `codex login` and sign in with your ChatGPT account, then re-run `:AgentifyStatus`."
        end

        if report.ready and self.opts.auth.subscription_only and report.auth.method ~= "subscription" then
          report.ready = false
          report.error = "Codex is authenticated with API-key billing; Agentify only uses subscription sessions."
          report.setup_hint = "Run `codex login` to use your ChatGPT subscription (hour-based limits), or set `auth.subscription_only = false` to allow API-key billing."
        end

        callback(report)
      end)
    end)
  end)
end

-- Maps the app-server account object onto the provider-neutral auth shape.
function M.normalize_account(account)
  if not account then
    return { logged_in = false }
  end

  if account.type == "chatgpt" then
    return {
      logged_in = true,
      method = "subscription",
      label = account.email or "chatgpt",
      plan = account.planType,
    }
  end

  return {
    logged_in = true,
    method = "api_key",
    label = "api key",
    plan = nil,
  }
end

function M.new(opts)
  return CodexProvider.new(opts)
end

return M
