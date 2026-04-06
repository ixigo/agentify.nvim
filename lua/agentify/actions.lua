local render = require("agentify.render")
local state = require("agentify.state")

local M = {}

local function resolve_bufnr(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end

  return bufnr
end

local function next_word_fragment(text)
  local leading = text:match("^(%s*)") or ""
  local rest = text:sub(#leading + 1)

  if rest == "" then
    return text
  end

  local token = rest:match("^%S+") or rest
  local trailing = rest:sub(#token + 1):match("^(%s*)") or ""

  return leading .. token .. trailing
end

local function apply_suggestion(bufnr, text)
  local buffer_state = state.get_buffer(bufnr)
  local suggestion = buffer_state.suggestion
  if not suggestion or text == "" then
    return false
  end

  buffer_state.suppress_text_changed = true
  render.clear(bufnr)
  state.clear_suggestion(bufnr)

  vim.api.nvim_buf_set_text(bufnr, suggestion.row, suggestion.col, suggestion.row, suggestion.col, { text })

  if vim.api.nvim_get_current_buf() == bufnr then
    vim.api.nvim_win_set_cursor(0, { suggestion.row + 1, suggestion.col + #text })
  end

  return true
end

function M.get(bufnr)
  bufnr = resolve_bufnr(bufnr)
  return state.get_buffer(bufnr).suggestion
end

function M.has(bufnr)
  return M.get(bufnr) ~= nil
end

function M.accept(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local suggestion = M.get(bufnr)
  if not suggestion then
    return false
  end

  return apply_suggestion(bufnr, suggestion.text)
end

function M.accept_word(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local suggestion = M.get(bufnr)
  if not suggestion then
    return false
  end

  return apply_suggestion(bufnr, next_word_fragment(suggestion.text))
end

function M.dismiss(bufnr)
  bufnr = resolve_bufnr(bufnr)
  render.clear(bufnr)
  state.clear_suggestion(bufnr)
  return true
end

return M

