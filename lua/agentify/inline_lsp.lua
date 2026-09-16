-- Neovim 0.12+ frontend: exposes Agentify as an in-process LSP server that answers
-- textDocument/inlineCompletion, so ghost text is rendered and accepted by
-- vim.lsp.inline_completion instead of the plugin's own extmarks.
local actions = require("agentify.actions")
local config = require("agentify.config")
local log = require("agentify.log")

local uv = vim.uv or vim.loop

local M = {
  opts = nil,
  deps = nil,
  client_id = nil,
  manual_next = {},
}

local INVOKED = 1

function M.is_supported()
  return vim.lsp ~= nil and vim.lsp.inline_completion ~= nil and vim.lsp.start ~= nil
end

local function completor_namespace()
  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    if name:find("inline_completion", 1, true) then
      return id
    end
  end

  return nil
end

-- Builds the `cmd` function for vim.lsp.start. `deps.compute(bufnr, { manual = bool }, cb)`
-- must return a handle with `cancel()` and call `cb(text_or_nil, source)` exactly once.
function M.make_server(deps)
  return function(dispatchers)
    local closing = false
    local next_id = 0
    local inflight = {}
    local inflight_by_buf = {}

    local function respond(callback, err, result)
      vim.schedule(function()
        callback(err, result)
      end)
    end

    local function cancel_buffer(bufnr, reason)
      local id = inflight_by_buf[bufnr]
      if not id then
        return
      end

      local handle = inflight[id]
      inflight[id] = nil
      inflight_by_buf[bufnr] = nil
      if handle and handle.cancel then
        pcall(handle.cancel, reason)
      end
    end

    local server = {}

    function server.request(method, params, callback, notify_reply_callback)
      next_id = next_id + 1
      local id = next_id

      if notify_reply_callback then
        pcall(notify_reply_callback, id)
      end

      if method == "initialize" then
        respond(callback, nil, {
          capabilities = { inlineCompletionProvider = true },
          serverInfo = { name = "agentify", version = "0.2.0" },
        })
        return true, id
      end

      if method == "shutdown" then
        respond(callback, nil, vim.NIL)
        return true, id
      end

      if method == "textDocument/inlineCompletion" then
        local uri = params and params.textDocument and params.textDocument.uri
        local bufnr = uri and vim.uri_to_bufnr(uri) or vim.api.nvim_get_current_buf()
        local manual = M.manual_next[bufnr] == true
          or (params and params.context and params.context.triggerKind == INVOKED)
        M.manual_next[bufnr] = nil

        cancel_buffer(bufnr, "superseded")

        local finished = false
        local handle = deps.compute(bufnr, { manual = manual }, function(text)
          if finished then
            return
          end
          finished = true

          if inflight[id] then
            inflight[id] = nil
            inflight_by_buf[bufnr] = nil
          end

          if text and text ~= "" then
            -- An explicit empty range at the request position makes Neovim apply the
            -- accept with nvim_buf_set_text instead of nvim_paste.
            local position = params and params.position
            local item = { insertText = text }
            if position then
              item.range = { start = position, ["end"] = position }
            end
            respond(callback, nil, { items = { item } })
          else
            respond(callback, nil, { items = {} })
          end
        end)

        if not finished then
          inflight[id] = handle
          inflight_by_buf[bufnr] = id
        end

        return true, id
      end

      respond(callback, { code = -32601, message = ("method not found: %s"):format(method) }, nil)
      return true, id
    end

    function server.notify(method, params)
      if method == "$/cancelRequest" and params and params.id then
        local handle = inflight[params.id]
        if handle then
          inflight[params.id] = nil
          for bufnr, id in pairs(inflight_by_buf) do
            if id == params.id then
              inflight_by_buf[bufnr] = nil
            end
          end
          pcall(handle.cancel, "lsp-cancelled")
        end
      elseif method == "exit" then
        closing = true
      end

      return true
    end

    function server.is_closing()
      return closing
    end

    function server.terminate()
      closing = true
      for id, handle in pairs(inflight) do
        inflight[id] = nil
        pcall(handle.cancel, "terminated")
      end
      inflight_by_buf = {}
      if dispatchers and dispatchers.on_exit then
        dispatchers.on_exit(0, 0)
      end
    end

    return server
  end
end

function M.attach(bufnr)
  if not M.is_supported() or not M.opts then
    return false
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local enabled = config.is_buffer_enabled(M.opts, bufnr)
  if not enabled then
    return false
  end

  local client_id = vim.lsp.start({
    name = "agentify",
    cmd = M.make_server(M.deps),
    root_dir = uv.cwd(),
  }, {
    bufnr = bufnr,
    silent = true,
  })

  if not client_id then
    log.warn("failed to start agentify inline completion client")
    return false
  end

  M.client_id = client_id
  -- The buffer marker is what turns inline completion on; the client marker defaults to
  -- enabled. Neovim creates the completor when the client finishes attaching.
  vim.lsp.inline_completion.enable(true, { bufnr = bufnr })
  return true
end

local function completor_group(bufnr)
  local group = ("nvim.lsp.inline_completion:%d"):format(bufnr)
  local ok = pcall(vim.api.nvim_get_autocmds, { group = group })
  return ok and group or nil
end

function M.setup(opts, deps)
  M.opts = opts
  M.deps = deps
  M.manual_next = {}

  local group = vim.api.nvim_create_augroup("AgentifyInlineLsp", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(args)
      vim.schedule(function()
        M.attach(args.buf)
      end)
    end,
  })

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.attach(bufnr)
    end
  end
end

function M.suggest(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not M.attach(bufnr) then
    return false, "buffer is not eligible"
  end

  local group = completor_group(bufnr)
  if not group then
    return false, "inline completion is not active for this buffer yet"
  end

  M.manual_next[bufnr] = true
  local ok = pcall(vim.api.nvim_exec_autocmds, "CursorMovedI", { group = group, buffer = bufnr })
  if not ok then
    M.manual_next[bufnr] = nil
    return false, "could not trigger inline completion"
  end

  return true, nil
end

function M.accept(bufnr)
  if not M.is_supported() then
    return false
  end

  return vim.lsp.inline_completion.get({ bufnr = bufnr })
end

function M.accept_word(bufnr)
  if not M.is_supported() then
    return false
  end

  return vim.lsp.inline_completion.get({
    bufnr = bufnr,
    on_accept = function(item)
      if type(item.insert_text) == "string" then
        item.insert_text = actions.next_word_fragment(item.insert_text)
      end
      return item
    end,
  })
end

function M.dismiss(bufnr)
  if not M.is_supported() then
    return false
  end

  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local had = M.has_suggestion(bufnr)
  vim.lsp.inline_completion.enable(false, { bufnr = bufnr })
  vim.lsp.inline_completion.enable(true, { bufnr = bufnr })
  return had
end

function M.has_suggestion(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local ns = completor_namespace()
  if not ns or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  return #marks > 0
end

return M
