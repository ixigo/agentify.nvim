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

local function split_inserted_lines(text)
  return vim.split(text, "\n", { plain = true, trimempty = false })
end

local function cursor_col_after_insert(base_col, inserted_lines)
  local raw_col
  if #inserted_lines == 1 then
    raw_col = base_col + #inserted_lines[1]
  else
    raw_col = #inserted_lines[#inserted_lines]
  end

  if not vim.api.nvim_get_mode().mode:match("^i") and raw_col > 0 then
    return raw_col - 1
  end

  return raw_col
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

  local inserted_lines = split_inserted_lines(text)
  vim.api.nvim_buf_set_text(bufnr, suggestion.row, suggestion.col, suggestion.row, suggestion.col, inserted_lines)

  if vim.api.nvim_get_current_buf() == bufnr then
    local row = suggestion.row + #inserted_lines
    local col = cursor_col_after_insert(suggestion.col, inserted_lines)
    vim.api.nvim_win_set_cursor(0, { row, col })
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
