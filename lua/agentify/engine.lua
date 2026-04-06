local actions = require("agentify.actions")
local config = require("agentify.config")
local context = require("agentify.context")
local lsp = require("agentify.lsp")
local local_suggest = require("agentify.local_suggest")
local log = require("agentify.log")
local render = require("agentify.render")
local state = require("agentify.state")
local template_suggest = require("agentify.template_suggest")

local uv = vim.uv or vim.loop

local M = {
  opts = nil,
  provider = nil,
}

local function resolve_bufnr(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end

  return bufnr
end

function M.should_auto_trigger(ctx, opts)
  if ctx.prefix_non_space_count < opts.suggestion.min_chars then
    return false
  end

  if ctx.line_prefix == "" and ctx.line_suffix == "" then
    return false
  end

  return true
end

function M.is_snapshot_stale(snapshot)
  return context.is_snapshot_stale(snapshot)
end

function M.cancel_request(bufnr, reason)
  bufnr = resolve_bufnr(bufnr)

  local buffer_state = state.get_buffer(bufnr)
  local active = buffer_state.active_request
  if not active then
    return false
  end

  buffer_state.active_request = nil
  if active.handle and active.handle.cancel then
    active.handle.cancel(reason or "cancelled")
  end

  return true
end

local function clear_buffer(bufnr, cancel_reason)
  M.cancel_request(bufnr, cancel_reason)
  actions.dismiss(bufnr)
end

local function buffer_eligible(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "invalid buffer"
  end

  return config.is_buffer_enabled(M.opts, bufnr)
end

function M._handle_provider_event(bufnr, request_token, snapshot, ctx, event)
  local buffer_state = state.get_buffer(bufnr)
  local active = buffer_state.active_request

  if not active or active.token ~= request_token then
    return
  end

  if event.type == "turn_started" then
    active.turn_id = event.turn_id
    return
  end

  if event.type == "error" then
    buffer_state.last_error = event.error
    buffer_state.active_request = nil
    actions.dismiss(bufnr)
    log.warn("provider error", { error = event.error })
    return
  end

  if event.type ~= "delta" and event.type ~= "completed" then
    return
  end

  if M.is_snapshot_stale(snapshot) then
    clear_buffer(bufnr, "stale")
    return
  end

  local text = context.sanitize_completion(ctx, event.text, M.opts)
  if text and text ~= "" then
    buffer_state.suggestion = {
      bufnr = bufnr,
      row = ctx.row,
      col = ctx.col,
      text = text,
      request_token = request_token,
    }
    render.show(bufnr, buffer_state.suggestion, M.opts)
  elseif event.type == "completed" then
    actions.dismiss(bufnr)
  end

  if event.type == "completed" then
    buffer_state.active_request = nil
  end
end

function M.request(bufnr, request_opts)
  request_opts = request_opts or {}
  bufnr = resolve_bufnr(bufnr)

  local ok, reason = buffer_eligible(bufnr)
  if not ok then
    clear_buffer(bufnr, "disabled")
    return false, reason
  end

  local ctx, build_reason = context.build(bufnr, M.opts)
  if not ctx then
    clear_buffer(bufnr, "invalid-context")
    return false, build_reason
  end
  ctx.lsp = lsp.snapshot(bufnr, ctx.row, M.opts)

  if not request_opts.manual and not M.should_auto_trigger(ctx, M.opts) then
    clear_buffer(bufnr, "below-threshold")
    return false, "below trigger threshold"
  end

  clear_buffer(bufnr, "superseded")

  local buffer_state = state.get_buffer(bufnr)

  if not request_opts.manual then
    local fast_completion = template_suggest.suggest(ctx, M.opts)
      or local_suggest.suggest(bufnr, ctx, M.opts)
      or lsp.suggest(bufnr, ctx, M.opts, function(text)
        return context.sanitize_completion(ctx, text, M.opts)
      end)
    if fast_completion then
      buffer_state.suggestion = {
        bufnr = bufnr,
        row = ctx.row,
        col = ctx.col,
        text = fast_completion.text,
        request_token = state.next_request(bufnr),
        source = fast_completion.source,
      }
      render.show(bufnr, buffer_state.suggestion, M.opts)
      log.debug("rendered fast suggestion", {
        bufnr = bufnr,
        source = fast_completion.source,
        text = fast_completion.text,
      })
      return true, fast_completion.reason or fast_completion.source
    end
  end

  local token = state.next_request(bufnr)
  local snapshot = context.snapshot(ctx)
  snapshot.require_insert_mode = not request_opts.manual

  local handle = M.provider:complete(ctx, function(event)
    vim.schedule(function()
      M._handle_provider_event(bufnr, token, snapshot, ctx, event)
    end)
  end)
  log.debug("queued completion request", {
    bufnr = bufnr,
    token = token,
    manual = request_opts.manual == true,
    filetype = ctx.filetype,
  })

  buffer_state.active_request = {
    token = token,
    handle = handle,
    snapshot = snapshot,
  }

  return true, nil
end

function M.schedule(bufnr)
  bufnr = resolve_bufnr(bufnr)

  local buffer_state = state.get_buffer(bufnr)
  if not buffer_state.timer then
    buffer_state.timer = uv.new_timer()
  end

  buffer_state.timer:stop()
  buffer_state.timer:start(M.opts.debounce_ms, 0, vim.schedule_wrap(function()
    M.request(bufnr, { manual = false })
  end))
end

function M.accept(bufnr)
  bufnr = resolve_bufnr(bufnr)
  M.cancel_request(bufnr, "accepted")
  return actions.accept(bufnr)
end

function M.accept_word(bufnr)
  bufnr = resolve_bufnr(bufnr)
  M.cancel_request(bufnr, "accepted-word")
  return actions.accept_word(bufnr)
end

function M.dismiss(bufnr)
  bufnr = resolve_bufnr(bufnr)
  M.cancel_request(bufnr, "dismissed")
  return actions.dismiss(bufnr)
end

function M.has_suggestion(bufnr)
  return actions.has(resolve_bufnr(bufnr))
end

function M.status(callback)
  local bufnr = vim.api.nvim_get_current_buf()
  local enabled, reason = buffer_eligible(bufnr)

  M.provider:status(function(report)
    report.buffer = {
      bufnr = bufnr,
      filetype = vim.bo[bufnr].filetype,
      enabled = enabled,
      reason = reason,
    }
    report.suggestion = actions.get(bufnr)
    report.logs = log.entries()
    callback(report)
  end)
end

function M.setup(opts, provider)
  M.opts = opts
  M.provider = provider

  local group = vim.api.nvim_create_augroup("Agentify", { clear = true })

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
    group = group,
    callback = function(args)
      local buffer_state = state.get_buffer(args.buf)
      if buffer_state.suppress_text_changed then
        buffer_state.suppress_text_changed = false
        return
      end

      M.schedule(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    callback = function(args)
      if not M.opts.codex.warmup_on_insert or not M.provider.warmup then
        return
      end

      local ok = buffer_eligible(args.buf)
      if not ok then
        return
      end

      M.provider:warmup(function(_, err)
        if err then
          log.debug("provider warmup failed", { error = err })
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("CursorMovedI", {
    group = group,
    callback = function(args)
      local buffer_state = state.get_buffer(args.buf)
      if buffer_state.suggestion or buffer_state.active_request then
        local active = buffer_state.active_request
        if active and M.is_snapshot_stale(active.snapshot) then
          clear_buffer(args.buf, "cursor-moved")
          return
        end

        if buffer_state.suggestion then
          local cursor = vim.api.nvim_win_get_cursor(0)
          local suggestion = buffer_state.suggestion
          if cursor[1] - 1 ~= suggestion.row or cursor[2] ~= suggestion.col then
            clear_buffer(args.buf, "cursor-moved")
          end
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = group,
    callback = function(args)
      clear_buffer(args.buf, "left-insert-mode")
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      state.destroy_buffer(args.buf)
    end,
  })
end

return M
