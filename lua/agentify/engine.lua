local actions = require("agentify.actions")
local budget = require("agentify.budget")
local config = require("agentify.config")
local context = require("agentify.context")
local intent = require("agentify.intent")
local jump = require("agentify.jump")
local lsp = require("agentify.lsp")
local local_suggest = require("agentify.local_suggest")
local log = require("agentify.log")
local recall = require("agentify.recall")
local render = require("agentify.render")
local repo_context = require("agentify.repo_context")
local state = require("agentify.state")
local template_suggest = require("agentify.template_suggest")

local uv = vim.uv or vim.loop

local M = {
  opts = nil,
  provider = nil,
  frontend = "extmark",
  budget = nil,
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

local function line_at(bufnr, row)
  return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

local function split_lines(text)
  return vim.split(text, "\n", { plain = true, trimempty = false })
end

local function has_visible_text(text)
  return type(text) == "string" and text:match("%S") ~= nil
end

local function remember(bufnr, suggestion)
  if not M.opts.recall.enabled or not suggestion.line then
    return
  end

  local key = recall.key(suggestion.row, suggestion.line:sub(1, suggestion.col), suggestion.line:sub(suggestion.col + 1))
  recall.remember(bufnr, key, suggestion.text, M.opts.recall.max_entries)
end

-- Stores and renders a suggestion. `suggestion.line` is the buffer line at show time and
-- is what type-through and recall compare against later.
function M.show_suggestion(bufnr, suggestion, opts)
  opts = opts or {}
  local buffer_state = state.get_buffer(bufnr)

  suggestion.bufnr = bufnr
  suggestion.line = suggestion.line or line_at(bufnr, suggestion.row)
  suggestion.request_token = suggestion.request_token or state.next_request(bufnr)

  buffer_state.suggestion = suggestion
  render.show(bufnr, suggestion, M.opts)

  if opts.remember ~= false then
    remember(bufnr, suggestion)
  end

  return suggestion
end

-- Reconciles the visible suggestion with the current cursor and line.
-- Returns "kept" when nothing changed, "shortened" when the user typed the head of the
-- ghost text (type-through), or nil when the suggestion no longer applies.
function M.reconcile(bufnr)
  local buffer_state = state.get_buffer(bufnr)
  local suggestion = buffer_state.suggestion
  if not suggestion or vim.api.nvim_get_current_buf() ~= bufnr then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  if row ~= suggestion.row or col < suggestion.col then
    return nil
  end

  local line = line_at(bufnr, row)
  local previous = suggestion.line or ""

  if line:sub(1, suggestion.col) ~= previous:sub(1, suggestion.col) then
    return nil
  end

  if col == suggestion.col then
    return line == previous and "kept" or nil
  end

  if not M.opts.type_through then
    return nil
  end

  local typed_count = col - suggestion.col
  local first_line = split_lines(suggestion.text)[1]
  if typed_count > #first_line then
    return nil
  end

  if line:sub(suggestion.col + 1, col) ~= first_line:sub(1, typed_count) then
    return nil
  end

  -- The text after the cursor must be untouched too.
  if line:sub(col + 1) ~= previous:sub(suggestion.col + 1) then
    return nil
  end

  local remainder = suggestion.text:sub(typed_count + 1)
  if not has_visible_text(remainder) then
    actions.dismiss(bufnr)
    return nil
  end

  suggestion.col = col
  suggestion.text = remainder
  suggestion.line = line
  suggestion.source = suggestion.source or "provider"
  render.show(bufnr, suggestion, M.opts)
  remember(bufnr, suggestion)
  M.budget:count("type_through")
  log.debug("type-through shortened suggestion", { bufnr = bufnr, remaining = remainder })

  return "shortened"
end

-- Re-shows a remembered suggestion for the exact current cursor context, if any.
function M.recall_show(bufnr)
  if not M.opts.recall.enabled or vim.api.nvim_get_current_buf() ~= bufnr then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local line = line_at(bufnr, row)
  local text = recall.lookup(bufnr, recall.key(row, line:sub(1, col), line:sub(col + 1)))
  if not text then
    return false
  end

  M.show_suggestion(bufnr, {
    row = row,
    col = col,
    text = text,
    line = line,
    source = "recall",
  }, { remember = false })
  M.budget:count("recall")
  log.debug("recalled suggestion", { bufnr = bufnr, text = text })

  return true
end

function M.debounce_delay(bufnr)
  local buffer_state = state.get_buffer(bufnr)
  if buffer_state.active_request then
    return M.opts.debounce_busy_ms
  end

  return M.opts.debounce_ms
end

-- Shows a next-edit hint for the cursor position, used after an accept.
function M.hint_next_edit(bufnr)
  if not M.opts.jump.enabled then
    return
  end

  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() == bufnr then
      jump.suggest(bufnr, M.opts.jump)
    end
  end)
end

function M.jump(bufnr)
  return jump.jump(resolve_bufnr(bufnr))
end

function M.has_jump_hint(bufnr)
  return jump.has(resolve_bufnr(bufnr))
end

-- Asks for the next suggestion right away, used after an accept.
function M.prefetch(bufnr)
  if not M.opts.prefetch_after_accept then
    return
  end

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
      return
    end

    if not vim.api.nvim_get_mode().mode:match("^i") then
      return
    end

    M.request(bufnr, { manual = false })
  end)
end

local function notify_budget(reason)
  if not M.opts.budget.notify or not M.budget:should_announce(reason) then
    return
  end

  local report = M.budget:report()
  local message
  if reason == "budget" then
    message = ("Model suggestions paused: %d requests in the last hour (budget.max_requests_per_hour = %d). Fast suggestions continue; the model resumes in %s or after :AgentifyBudgetReset."):format(
      report.used,
      report.limit,
      budget.format_duration(report.resets_in)
    )
  elseif reason == "cooldown" then
    message = ("Provider reported a rate limit; model suggestions paused for %s. Fast suggestions continue."):format(
      budget.format_duration(report.paused_for or 0)
    )
  else
    return
  end

  vim.schedule(function()
    vim.notify("agentify.nvim: " .. message, vim.log.levels.WARN, { title = "agentify.nvim" })
  end)
end

-- Decides whether the model tier may be asked right now and records the request if so.
function M.provider_allowed(manual)
  local allowed, reason = M.budget:allow(os.time(), manual)
  if not allowed then
    M.budget:skip(reason)
    notify_budget(reason)
    log.debug("provider request skipped", { reason = reason })
    return false, reason
  end

  M.budget:record(os.time())
  return true, nil
end

-- Pauses the model tier when a provider error looks like a rate limit.
function M.note_provider_error(err)
  if budget.is_rate_limit(err) and M.opts.budget.rate_limit_cooldown_s > 0 then
    M.budget:pause(M.opts.budget.rate_limit_cooldown_s, "rate_limit")
    notify_budget("cooldown")
    log.warn("provider rate limited; pausing model suggestions", { error = err })
  end
end

function M.reset_budget()
  M.budget:resume(true)
  return true
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
    M.note_provider_error(event.error)
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
    M.show_suggestion(bufnr, {
      row = ctx.row,
      col = ctx.col,
      text = text,
      line = ctx.line,
      request_token = request_token,
      source = "provider",
    }, { remember = event.type == "completed" })
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
      M.show_suggestion(bufnr, {
        row = ctx.row,
        col = ctx.col,
        text = fast_completion.text,
        line = ctx.line,
        source = fast_completion.source,
      })
      log.debug("rendered fast suggestion", {
        bufnr = bufnr,
        source = fast_completion.source,
        text = fast_completion.text,
      })
      M.budget:count("fast")
      if not continue_to_provider then
        return true, fast_completion.reason or fast_completion.source
      end
    end
  end

  local allowed, skip_reason = M.provider_allowed(request_opts.manual)
  if not allowed then
    return buffer_state.suggestion ~= nil, ("provider skipped: %s"):format(skip_reason)
  end

  local token = state.next_request(bufnr)
  local snapshot = context.snapshot(ctx)
  snapshot.require_insert_mode = not request_opts.manual

  -- The handle exists before the provider call so a cancel during repo-context
  -- collection is honoured.
  local handle = { cancelled = false, inner = nil, turn_id = nil }
  function handle.cancel(reason)
    if handle.cancelled then
      return
    end
    handle.cancelled = true
    if handle.inner and handle.inner.cancel then
      handle.inner.cancel(reason or "cancelled")
    end
  end

  buffer_state.active_request = {
    token = token,
    handle = handle,
    snapshot = snapshot,
    preserve_existing = buffer_state.suggestion ~= nil,
  }

  repo_context.collect(ctx, M.opts, function(repo)
    if handle.cancelled then
      return
    end

    local active = buffer_state.active_request
    if not active or active.token ~= token then
      return
    end

    ctx.repo = repo
    handle.inner = M.provider:complete(ctx, function(event)
      vim.schedule(function()
        M._handle_provider_event(bufnr, token, snapshot, ctx, event)
      end)
    end)
    log.debug("queued completion request", {
      bufnr = bufnr,
      token = token,
      manual = request_opts.manual == true,
      filetype = ctx.filetype,
      repo_symbols = repo and #repo.symbols or 0,
    })
  end)

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
      M.budget:count("fast")
      finish(fast_completion.text, fast_completion.source)
      return handle
    end
  end

  if not M.provider_allowed(request_opts.manual) then
    finish(nil)
    return handle
  end

  local snapshot = context.snapshot(ctx)
  snapshot.require_insert_mode = not request_opts.manual

  repo_context.collect(ctx, M.opts, function(repo)
    if done then
      return
    end

    ctx.repo = repo
    handle.inner = M.provider:complete(ctx, function(event)
      vim.schedule(function()
        if done then
          return
        end

        if event.type == "error" then
          log.warn("provider error", { error = event.error })
          M.note_provider_error(event.error)
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
  buffer_state.timer:start(M.debounce_delay(bufnr), 0, vim.schedule_wrap(function()
    M.request(bufnr, { manual = false })
  end))
end

function M.accept(bufnr)
  bufnr = resolve_bufnr(bufnr)
  if M.frontend == "lsp" then
    local accepted = inline_lsp().accept(bufnr)
    if accepted then
      -- Neovim applies the accept on the next tick; hint after it lands.
      vim.defer_fn(function()
        M.hint_next_edit(bufnr)
      end, 20)
    end
    return accepted
  end

  M.cancel_request(bufnr, "accepted")
  local accepted = actions.accept(bufnr)
  if accepted then
    M.prefetch(bufnr)
    M.hint_next_edit(bufnr)
  end

  return accepted
end

-- Inserts part of the suggestion and keeps the rest visible at the new cursor position.
local function accept_fragment(bufnr, fragment_of, reason)
  M.cancel_request(bufnr, reason)

  local suggestion = actions.get(bufnr)
  if not suggestion then
    return false
  end

  local fragment = fragment_of(suggestion.text)
  local remainder = suggestion.text:sub(#fragment + 1)
  local source = suggestion.source

  if not actions.apply(bufnr, fragment) then
    return false
  end

  if has_visible_text(remainder) then
    local inserted = split_lines(fragment)
    local row = suggestion.row + #inserted - 1
    local col = #inserted == 1 and (suggestion.col + #fragment) or #inserted[#inserted]
    M.show_suggestion(bufnr, {
      row = row,
      col = col,
      text = remainder,
      source = source,
    })
  else
    M.prefetch(bufnr)
    M.hint_next_edit(bufnr)
  end

  return true
end

function M.accept_word(bufnr)
  bufnr = resolve_bufnr(bufnr)
  if M.frontend == "lsp" then
    return inline_lsp().accept_word(bufnr)
  end

  return accept_fragment(bufnr, actions.next_word_fragment, "accepted-word")
end

function M.accept_line(bufnr)
  bufnr = resolve_bufnr(bufnr)
  if M.frontend == "lsp" then
    return inline_lsp().accept_line(bufnr)
  end

  return accept_fragment(bufnr, actions.first_line_fragment, "accepted-line")
end

function M.dismiss(bufnr)
  bufnr = resolve_bufnr(bufnr)
  if M.frontend == "lsp" then
    return inline_lsp().dismiss(bufnr)
  end

  M.cancel_request(bufnr, "dismissed")

  -- An explicit dismiss should not come straight back from the recall cache.
  local suggestion = actions.get(bufnr)
  if suggestion and suggestion.line then
    recall.forget(bufnr, recall.key(suggestion.row, suggestion.line:sub(1, suggestion.col), suggestion.line:sub(suggestion.col + 1)))
  end

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
    report.budget = M.budget:report()
    report.repo_context = repo_context.status(M.opts, bufnr)
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
  M.budget = budget.new(opts)

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

        -- Typing the ghost text keeps it; nothing to request.
        if M.reconcile(args.buf) then
          M.cancel_request(args.buf, "type-through")
          return
        end

        -- Backspacing into a prefix we already answered re-shows it instantly.
        if M.recall_show(args.buf) then
          M.cancel_request(args.buf, "recalled")
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
          local outcome = M.reconcile(args.buf)
          if outcome then
            if outcome == "shortened" then
              M.cancel_request(args.buf, "type-through")
            end
            return
          end

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

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(args)
      jump.on_cursor_moved(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(args)
      local buffer_state = state.get_buffer(args.buf)
      if not buffer_state.suppress_text_changed and jump.has(args.buf) then
        jump.clear(args.buf)
      end
    end,
  })

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
      recall.clear(args.buf)
      jump.clear(args.buf)
      state.destroy_buffer(args.buf)
    end,
  })
end

return M
