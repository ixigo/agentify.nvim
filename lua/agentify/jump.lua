-- Next-edit jump hints. After an accept, predicts where the cursor is likely to go next
-- (the nearest diagnostic below the cursor, or a placeholder such as TODO / pass / an
-- empty block) and shows a hint there. `jump()` moves the cursor to it.
--
-- Model-free by design so it costs nothing from the usage window.
local log = require("agentify.log")

local M = {
  hints = {},
  namespace = vim.api.nvim_create_namespace("agentify.nvim.jump"),
}

local PLACEHOLDERS = {
  { pattern = "TODO", reason = "TODO" },
  { pattern = "FIXME", reason = "FIXME" },
  { pattern = "XXX", reason = "XXX" },
  { pattern = "^%s*pass%s*$", reason = "empty body" },
  { pattern = "^%s*%.%.%.%s*$", reason = "placeholder" },
  { pattern = "{%s*}%s*[,;]?%s*$", reason = "empty block" },
  { pattern = "%(%s*%)%s*=>%s*{%s*}%s*[,;]?%s*$", reason = "empty arrow function" },
  { pattern = "[Nn]ot[ _]?[Ii]mplemented", reason = "not implemented" },
  { pattern = "unimplemented!%(", reason = "unimplemented!" },
  { pattern = "^%s*raise NotImplementedError", reason = "not implemented" },
}

local function resolve_bufnr(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

local function diagnostic_target(bufnr, row, opts)
  if not opts.diagnostics then
    return nil
  end

  local ok, diagnostics = pcall(vim.diagnostic.get, bufnr)
  if not ok or type(diagnostics) ~= "table" then
    return nil
  end

  local best
  for _, diagnostic in ipairs(diagnostics) do
    local severity = diagnostic.severity or vim.diagnostic.severity.HINT
    if diagnostic.lnum > row
      and diagnostic.lnum <= row + opts.max_distance
      and severity <= opts.max_severity
      and (not best or diagnostic.lnum < best.lnum)
    then
      best = diagnostic
    end
  end

  if not best then
    return nil
  end

  return {
    row = best.lnum,
    col = best.col or 0,
    reason = ("%s: %s"):format(
      (best.severity == vim.diagnostic.severity.ERROR) and "error" or "warning",
      (best.message or ""):gsub("\n.*", ""):sub(1, 60)
    ),
    kind = "diagnostic",
  }
end

local function placeholder_target(bufnr, row, opts)
  if not opts.placeholders then
    return nil
  end

  local last = math.min(vim.api.nvim_buf_line_count(bufnr), row + 1 + opts.max_distance)
  local lines = vim.api.nvim_buf_get_lines(bufnr, row + 1, last, false)

  for offset, line in ipairs(lines) do
    for _, placeholder in ipairs(PLACEHOLDERS) do
      local start, finish = line:find(placeholder.pattern)
      if start then
        local col
        if placeholder.reason == "empty block" or placeholder.reason == "empty arrow function" then
          -- inside the braces
          local brace = line:find("{", start, true)
          col = brace and brace or #line
        else
          col = math.max(0, finish or #line)
        end
        return {
          row = row + offset,
          col = math.min(col, #line),
          reason = placeholder.reason,
          kind = "placeholder",
        }
      end
    end
  end

  return nil
end

-- Finds the most likely next edit location after `row` (0-based), or nil.
function M.find_target(bufnr, row, opts)
  bufnr = resolve_bufnr(bufnr)
  return diagnostic_target(bufnr, row, opts) or placeholder_target(bufnr, row, opts)
end

function M.clear(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local hint = M.hints[bufnr]
  M.hints[bufnr] = nil
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.namespace, 0, -1)
  end
  return hint ~= nil
end

function M.show(bufnr, target, opts)
  bufnr = resolve_bufnr(bufnr)
  M.clear(bufnr)

  if not target or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if target.row >= line_count then
    return false
  end

  local label = ("⇣ next edit: %s"):format(target.reason)
  local marks = {}
  marks[#marks + 1] = vim.api.nvim_buf_set_extmark(bufnr, M.namespace, target.row, 0, {
    virt_text = { { "  " .. label, opts.highlight } },
    virt_text_pos = "eol",
    hl_mode = "combine",
  })

  -- If the target is off-screen, also point at it from the cursor line.
  local winid = vim.fn.bufwinid(bufnr)
  if winid ~= -1 then
    local last_visible = vim.fn.line("w$", winid) - 1
    local cursor = vim.api.nvim_win_get_cursor(winid)
    if target.row > last_visible and cursor[1] - 1 < line_count then
      marks[#marks + 1] = vim.api.nvim_buf_set_extmark(bufnr, M.namespace, cursor[1] - 1, 0, {
        virt_text = { { ("  ↓ next edit at line %d (%s)"):format(target.row + 1, target.reason), opts.highlight } },
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
    end
  end

  M.hints[bufnr] = {
    target = target,
    marks = marks,
    origin_row = vim.api.nvim_win_get_cursor(0)[1] - 1,
  }
  log.debug("jump hint shown", { bufnr = bufnr, row = target.row, reason = target.reason })
  return true
end

-- Computes and shows a hint for the cursor position. Returns the target or nil.
function M.suggest(bufnr, opts)
  bufnr = resolve_bufnr(bufnr)
  if not opts.enabled or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    return nil
  end

  local row = vim.api.nvim_win_get_cursor(winid)[1] - 1
  local target = M.find_target(bufnr, row, opts)
  if not target then
    M.clear(bufnr)
    return nil
  end

  M.show(bufnr, target, opts)
  return target
end

function M.get(bufnr)
  local hint = M.hints[resolve_bufnr(bufnr)]
  return hint and hint.target or nil
end

function M.has(bufnr)
  return M.get(bufnr) ~= nil
end

-- Moves the cursor to the hinted location and clears the hint.
function M.jump(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local hint = M.hints[bufnr]
  if not hint then
    return false
  end

  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    M.clear(bufnr)
    return false
  end

  local target = hint.target
  local line = vim.api.nvim_buf_get_lines(bufnr, target.row, target.row + 1, false)[1] or ""
  local col = math.min(target.col, #line)
  -- Clear first so the CursorMoved autocmd triggered by the move finds nothing to do.
  M.clear(bufnr)
  vim.api.nvim_win_set_cursor(winid, { target.row + 1, col })
  return true
end

-- Autocmd hook: drop the hint once the cursor leaves the line it was shown from.
function M.on_cursor_moved(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local hint = M.hints[bufnr]
  if not hint then
    return
  end

  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  if row ~= hint.origin_row and row ~= hint.target.row then
    M.clear(bufnr)
  end
end

function M.reset()
  for bufnr in pairs(M.hints) do
    M.clear(bufnr)
  end
  M.hints = {}
end

return M
