local actions = require("agentify.actions")
local config = require("agentify.config")
local context = require("agentify.context")
local intent = require("agentify.intent")
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
  frontend = "extmark",
}

local function resolve_bufnr(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end

  return bufnr
end

local function inline_lsp()
  return require("agentify.inline_lsp")
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

-- Builds the completion context for the cursor position, including LSP and intent signal.
function M.build_context(bufnr, manual)
  local ctx, reason = context.build(bufnr, M.opts)
  if not ctx then
    return nil, reason
  end

  ctx.lsp = lsp.snapshot(bufnr, ctx.row, M.opts)
  ctx.intent = intent.analyze(bufnr, ctx, M.opts)
  ctx.manual = manual == true

  return ctx, nil
end

-- Runs the zero-latency tier (templates, buffer reuse, LSP items).
-- Returns the fast completion (or nil) and whether the provider should still be asked.
function M.fast_suggestion(bufnr, ctx)
  local fast_completion = template_suggest.suggest(ctx, M.opts)
  if not intent.prefers_provider(ctx) then
    fast_completion = fast_completion
      or local_suggest.suggest(bufnr, ctx, M.opts)
      or lsp.suggest(bufnr, ctx, M.opts, function(text)
        return context.sanitize_completion(ctx, text, M.opts)
      end)
  end

  return fast_completion, intent.should_continue_provider(ctx, fast_completion)
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
    if not active.preserve_existing then
      actions.dismiss(bufnr)
    end
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
  elseif event.type == "completed" and not active.preserve_existing then
    actions.dismiss(bufnr)
  end

  if event.type == "completed" then
    buffer_state.active_request = nil
  end
end

function M.request(bufnr, request_opts)
  request_opts = request_opts or {}
  bufnr = resolve_bufnr(bufnr)

  if M.frontend == "lsp" then
    if request_opts.manual then
      return inline_lsp().suggest(bufnr)
    end
    return false, "automatic requests are driven by vim.lsp.inline_completion"
  end

  local ok, reason = buffer_eligible(bufnr)
  if not ok then
    clear_buffer(bufnr, "disabled")
    return false, reason
  end

  local ctx, build_reason = M.build_context(bufnr, request_opts.manual)
  if not ctx then
    clear_buffer(bufnr, "invalid-context")
    return false, build_reason
  end

  if not request_opts.manual and not M.should_auto_trigger(ctx, M.opts) then
    clear_buffer(bufnr, "below-threshold")
    return false, "below trigger threshold"
  end

  clear_buffer(bufnr, "superseded")

  local buffer_state = state.get_buffer(bufnr)

  if not request_opts.manual then
    local fast_completion, continue_to_provider = M.fast_suggestion(bufnr, ctx)
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
      if not continue_to_provider then
        return true, fast_completion.reason or fast_completion.source
      end
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
    preserve_existing = buffer_state.suggestion ~= nil,
  }

  return true, nil
end

-- Headless variant of `request` used by the LSP frontend: computes the suggestion text
-- for the cursor and hands it to `callback(text_or_nil, source)` exactly once.
-- Returns a handle with `cancel(reason)`.
function M.compute(bufnr, request_opts, callback)
  request_opts = request_opts or {}
  bufnr = resolve_bufnr(bufnr)

  local handle = { cancelled = false, inner = nil }
  local done = false

  local function finish(text, source)
    if done then
      return
    end
    done = true
    callback(text, source)
  end

  function handle.cancel(reason)
    if handle.cancelled then
      return
    end
    handle.cancelled = true
    done = true
    if handle.inner and handle.inner.cancel then
      handle.inner.cancel(reason or "cancelled")
    end
  end

  if not buffer_eligible(bufnr) then
    finish(nil)
    return handle
  end

  local ctx = M.build_context(bufnr, request_opts.manual)
  if not ctx then
    finish(nil)
    return handle
  end

  if not request_opts.manual and not M.should_auto_trigger(ctx, M.opts) then
    finish(nil)
    return handle
  end

  if not request_opts.manual then
    local fast_completion, continue_to_provider = M.fast_suggestion(bufnr, ctx)
    if fast_completion and not continue_to_provider then
      finish(fast_completion.text, fast_completion.source)
      return handle
    end
  end

  local snapshot = context.snapshot(ctx)
  snapshot.require_insert_mode = not request_opts.manual

  handle.inner = M.provider:complete(ctx, function(event)
    vim.schedule(function()
      if done then
        return
      end

      if event.type == "error" then
        log.warn("provider error", { error = event.error })
        finish(nil)
        return
      end

      if event.type ~= "completed" then
        return
      end

      if M.is_snapshot_stale(snapshot) then
        finish(nil)
        return
      end

      finish(context.sanitize_completion(ctx, event.text, M.opts), "provider")
    end)
  end)

  return handle
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
  if M.frontend == "lsp" then
    return inline_lsp().accept(bufnr)
  end

  M.cancel_request(bufnr, "accepted")
  return actions.accept(bufnr)
end

function M.accept_word(bufnr)
  bufnr = resolve_bufnr(bufnr)
  if M.frontend == "lsp" then
    return inline_lsp().accept_word(bufnr)
  end

  M.cancel_request(bufnr, "accepted-word")
  return actions.accept_word(bufnr)
end

function M.dismiss(bufnr)
  bufnr = resolve_bufnr(bufnr)
  if M.frontend == "lsp" then
    return inline_lsp().dismiss(bufnr)
  end

  M.cancel_request(bufnr, "dismissed")
  return actions.dismiss(bufnr)
end

function M.has_suggestion(bufnr)
  bufnr = resolve_bufnr(bufnr)
  if M.frontend == "lsp" then
    return inline_lsp().has_suggestion(bufnr)
  end

  return actions.has(bufnr)
end

function M.status(callback)
  local bufnr = vim.api.nvim_get_current_buf()
  local enabled, reason = buffer_eligible(bufnr)

  M.provider:status(function(report)
    report.frontend = M.frontend
    report.buffer = {
      bufnr = bufnr,
      filetype = vim.bo[bufnr].filetype,
      enabled = enabled,
      reason = reason,
    }
    report.suggestion = M.frontend == "lsp" and nil or actions.get(bufnr)
    report.logs = log.entries()
    callback(report)
  end)
end

function M.setup(opts, provider)
  M.opts = opts
  M.provider = provider
  M.frontend = opts.frontend or "extmark"

  local group = vim.api.nvim_create_augroup("Agentify", { clear = true })

  if M.frontend ~= "lsp" then
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
  end

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    callback = function(args)
      if not M.opts.warmup_on_insert or not M.provider.warmup then
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

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      state.destroy_buffer(args.buf)
    end,
  })
end

return M
