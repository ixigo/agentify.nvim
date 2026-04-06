local M = {}

local severity_labels = {
  [vim.diagnostic.severity.ERROR] = "Error",
  [vim.diagnostic.severity.WARN] = "Warn",
  [vim.diagnostic.severity.INFO] = "Info",
  [vim.diagnostic.severity.HINT] = "Hint",
}

local function get_clients(bufnr)
  if not vim.lsp then
    return {}
  end

  if vim.lsp.get_clients then
    return vim.lsp.get_clients({ bufnr = bufnr })
  end

  local active = vim.lsp.get_active_clients and vim.lsp.get_active_clients() or {}
  local attached = {}
  for _, client in ipairs(active) do
    if client.attached_buffers and client.attached_buffers[bufnr] then
      attached[#attached + 1] = client
    end
  end

  return attached
end

local function client_names(clients)
  local names = {}
  for _, client in ipairs(clients) do
    names[#names + 1] = client.name
  end
  table.sort(names)
  return names
end

local function line_diagnostics(bufnr, row, limit)
  if not vim.diagnostic or not vim.diagnostic.get then
    return {}
  end

  local diagnostics = vim.diagnostic.get(bufnr, { lnum = row }) or {}
  local lines = {}

  for index, diagnostic in ipairs(diagnostics) do
    if index > limit then
      break
    end

    local label = severity_labels[diagnostic.severity] or "Info"
    lines[#lines + 1] = ("%s: %s"):format(label, diagnostic.message)
  end

  return lines
end

local function supports_completion(client, bufnr)
  if client.supports_method then
    return client:supports_method("textDocument/completion", { bufnr = bufnr })
  end

  return client.server_capabilities and client.server_capabilities.completionProvider ~= nil
end

local function current_word_fragment(prefix)
  return prefix:match("([%a_][%w_]*)$")
end

local function should_query_completion(ctx, opts)
  local fragment = current_word_fragment(ctx.line_prefix)
  if fragment and #fragment >= opts.lsp.min_chars then
    return true
  end

  return ctx.line_prefix:match("[%.:>]$") ~= nil
end

local function completion_params(winid)
  local util = vim.lsp.util
  local params = util.make_position_params(winid)
  params.context = {
    triggerKind = 1,
  }
  return params
end

local function list_items(result)
  if not result then
    return {}
  end

  if vim.islist(result) then
    return result
  end

  return result.items or {}
end

local function sanitize_snippet(text)
  text = text:gsub("%${%d+:([^}]-)}", "%1")
  text = text:gsub("%${%d+|([^}]-)|}", function(choices)
    return (choices:match("([^,|]+)")) or ""
  end)
  text = text:gsub("%${%d+}", "")
  text = text:gsub("%$%d+", "")
  return text
end

local function item_new_text(item)
  local text_edit = item.textEdit
  local text = text_edit and (text_edit.newText or (text_edit.insert and text_edit.insert.newText)) or nil

  if not text or text == "" then
    text = item.insertText or item.label
  end

  if item.insertTextFormat == 2 and text then
    text = sanitize_snippet(text)
  end

  return text
end

local function item_detail(item)
  local kind = item.kind and tostring(item.kind) or nil
  if item.detail and item.detail ~= "" then
    return ("%s: %s"):format(item.label or "<unknown>", item.detail)
  end

  return item.label and kind and ("%s (kind %s)"):format(item.label, kind) or item.label
end

local function best_completion_item(ctx, opts, items, sanitize)
  local fragment = current_word_fragment(ctx.line_prefix)
  local best = nil

  for _, item in ipairs(items) do
    local candidate = item_new_text(item)
    if candidate and candidate ~= "" then
      local insertion = candidate
      if fragment and fragment ~= "" and vim.startswith(insertion, fragment) then
        insertion = insertion:sub(#fragment + 1)
      end

      insertion = sanitize(insertion)
      if insertion and insertion ~= "" then
        local score = 0
        if fragment and fragment ~= "" then
          if vim.startswith(candidate, fragment) then
            score = score + 50
          elseif item.label and vim.startswith(item.label, fragment) then
            score = score + 40
          end
        end

        if item.kind == 2 or item.kind == 3 or item.kind == 6 then
          score = score + 10
        end

        if item.sortText and item.sortText ~= "" then
          score = score + math.max(0, 10 - #item.sortText)
        end

        score = score - #insertion

        if not best or score > best.score then
          best = {
            text = insertion,
            source = "lsp-completion",
            reason = "lsp-suggestion",
            label = item.label,
            score = score,
          }
        end
      end
    end
  end

  return best
end

function M.snapshot(bufnr, row, opts)
  if not opts.lsp.enabled then
    return nil
  end

  local clients = get_clients(bufnr)
  local names = client_names(clients)
  local diagnostics = line_diagnostics(bufnr, row, opts.lsp.max_diagnostics)

  if #names == 0 and #diagnostics == 0 then
    return nil
  end

  return {
    clients = names,
    diagnostics = diagnostics,
  }
end

function M.suggest(bufnr, ctx, opts, sanitize)
  if not opts.lsp.enabled or not should_query_completion(ctx, opts) then
    return nil
  end

  local clients = get_clients(bufnr)
  local has_completion = false
  for _, client in ipairs(clients) do
    if supports_completion(client, bufnr) then
      has_completion = true
      break
    end
  end

  if not has_completion then
    return nil
  end

  local responses = vim.lsp.buf_request_sync(
    bufnr,
    "textDocument/completion",
    completion_params(ctx.winid),
    opts.lsp.timeout_ms
  ) or {}

  local items = {}
  for _, response in pairs(responses) do
    if response and response.result then
      for _, item in ipairs(list_items(response.result)) do
        items[#items + 1] = item
      end
    end
  end

  if ctx.lsp then
    ctx.lsp.completions = {}
    for index = 1, math.min(#items, opts.lsp.max_completion_items) do
      ctx.lsp.completions[#ctx.lsp.completions + 1] = item_detail(items[index])
    end
  end

  if #items == 0 then
    return nil
  end

  return best_completion_item(ctx, opts, items, sanitize)
end

return M
