-- Edit prediction: after the user changes something, ask the model for the single most
-- likely follow-up edit elsewhere in the visible window (the same rename applied to
-- another occurrence, a matching call updated) and show it as strikethrough old text
-- plus ghost new text. `accept()` applies it.
local log = require("agentify.log")

local M = {
  predictions = {},
  namespace = vim.api.nvim_create_namespace("agentify.nvim.edit"),
}

vim.api.nvim_set_hl(0, "AgentifyEditOld", { default = true, strikethrough = true, link = nil, fg = "#9aa5b1" })
vim.api.nvim_set_hl(0, "AgentifyEditNew", { default = true, link = "DiffAdd" })
vim.api.nvim_set_hl(0, "AgentifyEditHint", { default = true, link = "DiagnosticVirtualTextHint" })

local function resolve_bufnr(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

-- Builds the window of lines around the cursor for the prompt.
function M.window(bufnr, row, opts)
  local count = vim.api.nvim_buf_line_count(bufnr)
  local start_row = math.max(0, row - opts.window_lines)
  local end_row = math.min(count, row + opts.window_lines + 1)
  return {
    start_row = start_row,
    lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false),
  }
end

-- Parses the model reply into a validated prediction or nil.
function M.parse(text, ctx)
  if type(text) ~= "string" then
    return nil
  end

  local start = text:find("{", 1, true)
  local finish = text:match(".*()}")
  if not start or not finish or finish < start then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, text:sub(start, finish))
  if not ok or type(decoded) ~= "table" or decoded.line == nil then
    return nil
  end

  local line = tonumber(decoded.line)
  local old, new = decoded.old, decoded.new
  if not line or type(old) ~= "string" or type(new) ~= "string" or old == "" or old == new then
    return nil
  end

  local row = math.floor(line) - 1
  if row == ctx.row then
    return nil
  end

  local window = ctx.window
  local index = row - window.start_row + 1
  local buffer_line = window.lines[index]
  if not buffer_line then
    return nil
  end

  local col = buffer_line:find(old, 1, true)
  if not col then
    return nil
  end

  return {
    row = row,
    col = col - 1,
    end_col = col - 1 + #old,
    old = old,
    new = new,
    line = buffer_line,
  }
end

function M.clear(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local had = M.predictions[bufnr] ~= nil
  M.predictions[bufnr] = nil
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.namespace, 0, -1)
  end
  return had
end

function M.show(bufnr, prediction, opts)
  bufnr = resolve_bufnr(bufnr)
  M.clear(bufnr)

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local current = vim.api.nvim_buf_get_lines(bufnr, prediction.row, prediction.row + 1, false)[1]
  if current ~= prediction.line then
    return false
  end

  local marks = {}
  marks[#marks + 1] = vim.api.nvim_buf_set_extmark(bufnr, M.namespace, prediction.row, prediction.col, {
    end_col = prediction.end_col,
    hl_group = "AgentifyEditOld",
    strict = false,
  })
  marks[#marks + 1] = vim.api.nvim_buf_set_extmark(bufnr, M.namespace, prediction.row, prediction.end_col, {
    virt_text = {
      { prediction.new, "AgentifyEditNew" },
      { "  ⇥ " .. opts.hint, "AgentifyEditHint" },
    },
    virt_text_pos = "inline",
    strict = false,
  })

  prediction.marks = marks
  M.predictions[bufnr] = prediction
  log.debug("edit prediction shown", { bufnr = bufnr, row = prediction.row, old = prediction.old, new = prediction.new })
  return true
end

function M.get(bufnr)
  return M.predictions[resolve_bufnr(bufnr)]
end

function M.has(bufnr)
  return M.get(bufnr) ~= nil
end

-- Applies the predicted edit. Returns true when the buffer changed.
function M.accept(bufnr, on_apply)
  bufnr = resolve_bufnr(bufnr)
  local prediction = M.predictions[bufnr]
  if not prediction then
    return false
  end

  local current = vim.api.nvim_buf_get_lines(bufnr, prediction.row, prediction.row + 1, false)[1]
  if current ~= prediction.line then
    M.clear(bufnr)
    return false
  end

  if on_apply then
    on_apply(bufnr)
  end

  M.clear(bufnr)
  vim.api.nvim_buf_set_text(bufnr, prediction.row, prediction.col, prediction.row, prediction.end_col, vim.split(prediction.new, "\n", { plain = true }))

  local winid = vim.fn.bufwinid(bufnr)
  if winid ~= -1 then
    local new_lines = vim.split(prediction.new, "\n", { plain = true })
    local row = prediction.row + #new_lines - 1
    local col = #new_lines == 1 and (prediction.col + #prediction.new) or #new_lines[#new_lines]
    local target_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local mode = vim.api.nvim_get_mode().mode
    if not mode:match("^i") and col > 0 and col >= #target_line then
      col = math.max(0, #target_line - 1)
    end
    pcall(vim.api.nvim_win_set_cursor, winid, { row + 1, math.min(col, #target_line) })
  end

  return true
end

function M.reset()
  for bufnr in pairs(M.predictions) do
    M.clear(bufnr)
  end
  M.predictions = {}
end

return M
