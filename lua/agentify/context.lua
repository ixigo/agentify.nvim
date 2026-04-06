local M = {}

local function line_at(bufnr, row)
  return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

local function strip_code_fences(text)
  local stripped = text:gsub("^```[%w_-]*\n?", "")
  stripped = stripped:gsub("\n?```$", "")
  return stripped
end

local function strip_prefix_duplication(prefix, text)
  if prefix ~= "" and vim.startswith(text, prefix) then
    return text:sub(#prefix + 1)
  end

  return text
end

local function trim_suffix_overlap(text, suffix)
  if suffix == "" or text == "" then
    return text
  end

  local max_overlap = math.min(#text, #suffix)

  for overlap = max_overlap, 1, -1 do
    if text:sub(#text - overlap + 1) == suffix:sub(1, overlap) then
      return text:sub(1, #text - overlap)
    end
  end

  return text
end

local function trim_trailing_blank_lines(lines)
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines, #lines)
  end

  return lines
end

local function split_lines(text)
  return vim.split(text, "\n", { plain = true, trimempty = false })
end

function M.build(bufnr, opts)
  local api = vim.api
  local winid = api.nvim_get_current_win()

  if api.nvim_win_get_buf(winid) ~= bufnr then
    return nil, "buffer is not active in the current window"
  end

  local cursor = api.nvim_win_get_cursor(winid)
  local row = cursor[1] - 1
  local col = cursor[2]
  local line = line_at(bufnr, row)
  local before_start = math.max(0, row - opts.suggestion.max_context_lines.before)
  local after_end = math.min(api.nvim_buf_line_count(bufnr), row + opts.suggestion.max_context_lines.after + 1)
  local line_prefix = line:sub(1, col)
  local line_suffix = line:sub(col + 1)
  local prefix_non_space_count = #(line_prefix:gsub("%s+", ""))

  return {
    bufnr = bufnr,
    winid = winid,
    row = row,
    col = col,
    changedtick = api.nvim_buf_get_changedtick(bufnr),
    filetype = vim.bo[bufnr].filetype,
    filepath = api.nvim_buf_get_name(bufnr),
    line = line,
    line_prefix = line_prefix,
    line_suffix = line_suffix,
    before_lines = api.nvim_buf_get_lines(bufnr, before_start, row, false),
    after_lines = api.nvim_buf_get_lines(bufnr, row + 1, after_end, false),
    expandtab = vim.bo[bufnr].expandtab,
    shiftwidth = vim.bo[bufnr].shiftwidth,
    tabstop = vim.bo[bufnr].tabstop,
    prefix_non_space_count = prefix_non_space_count,
  }
end

function M.snapshot(context)
  return {
    bufnr = context.bufnr,
    winid = context.winid,
    row = context.row,
    col = context.col,
    line = context.line,
    changedtick = context.changedtick,
  }
end

function M.is_snapshot_stale(snapshot)
  local api = vim.api

  if not api.nvim_buf_is_valid(snapshot.bufnr) then
    return true
  end

  if api.nvim_get_current_buf() ~= snapshot.bufnr then
    return true
  end

  if api.nvim_get_current_win() ~= snapshot.winid then
    return true
  end

  if snapshot.require_insert_mode ~= false and not api.nvim_get_mode().mode:match("^i") then
    return true
  end

  if api.nvim_buf_get_changedtick(snapshot.bufnr) ~= snapshot.changedtick then
    return true
  end

  local cursor = api.nvim_win_get_cursor(snapshot.winid)
  if cursor[1] - 1 ~= snapshot.row or cursor[2] ~= snapshot.col then
    return true
  end

  return line_at(snapshot.bufnr, snapshot.row) ~= snapshot.line
end

function M.sanitize_completion(context, raw_text, opts)
  if type(raw_text) ~= "string" then
    return nil
  end

  local text = raw_text:gsub("\r\n?", "\n")
  text = strip_code_fences(text)
  text = text:gsub("^Output:%s*", "")

  local lines = split_lines(text)
  local first_line = lines[1] or ""
  first_line = strip_prefix_duplication(context.line_prefix, first_line)
  lines[1] = first_line

  local multiline_enabled = opts
    and opts.suggestion
    and opts.suggestion.multiline
    and context.line_suffix == ""
    and #lines > 1

  if not multiline_enabled then
    first_line = trim_suffix_overlap(first_line, context.line_suffix)
    if first_line == "" then
      return nil
    end

    return first_line
  end

  local max_lines = opts.suggestion.max_lines or 1
  local sanitized = {}

  for index = 1, math.min(#lines, max_lines) do
    sanitized[#sanitized + 1] = lines[index]
  end

  trim_trailing_blank_lines(sanitized)
  if #sanitized == 0 then
    return nil
  end

  local has_visible_text = false
  for _, line in ipairs(sanitized) do
    if line:match("%S") then
      has_visible_text = true
      break
    end
  end

  if not has_visible_text then
    return nil
  end

  return table.concat(sanitized, "\n")
end

return M
