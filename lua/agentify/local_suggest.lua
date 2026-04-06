local context = require("agentify.context")

local M = {}

local function current_word_fragment(prefix)
  return prefix:match("([%a_][%w_]*)$")
end

local function candidate_ok(ctx, opts, text)
  if not text or text == "" then
    return nil
  end

  if text:find("\n", 1, true) or #text > opts.local_suggestions.max_suffix_length then
    return nil
  end

  return context.sanitize_completion(ctx, text, opts)
end

local function scan_window(bufnr, row, max_scan_lines)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local half_window = math.floor(max_scan_lines / 2)
  local start_row = math.max(0, row - half_window)
  local end_row = math.min(line_count, row + half_window + 1)
  return vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false), start_row
end

local function best_line_suffix(bufnr, ctx, opts)
  local lines, start_row = scan_window(bufnr, ctx.row, opts.local_suggestions.max_scan_lines)
  local best = nil
  local indent = ctx.line_prefix:match("^(%s*)") or ""

  for index, line in ipairs(lines) do
    local row = start_row + index - 1
    if row ~= ctx.row and vim.startswith(line, ctx.line_prefix) then
      local line_indent = line:match("^(%s*)") or ""
      if line_indent == indent then
        local candidate = candidate_ok(ctx, opts, line:sub(#ctx.line_prefix + 1))
        if candidate then
          local score = {
            distance = math.abs(row - ctx.row),
            length = #candidate,
          }

          if not best
            or score.distance < best.score.distance
            or (score.distance == best.score.distance and score.length < best.score.length)
          then
            best = {
              text = candidate,
              source = "buffer-line",
              score = score,
            }
          end
        end
      end
    end
  end

  return best
end

local function best_word_suffix(bufnr, ctx, opts)
  local fragment = current_word_fragment(ctx.line_prefix)
  if not fragment or #fragment < opts.local_suggestions.min_chars then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local candidates = {}

  for row, line in ipairs(lines) do
    for token in line:gmatch("[%a_][%w_]*") do
      if token ~= fragment and vim.startswith(token, fragment) then
        local suffix = token:sub(#fragment + 1)
        local candidate = candidate_ok(ctx, opts, suffix)
        if candidate then
          local entry = candidates[token]
          if not entry then
            candidates[token] = {
              count = 1,
              distance = math.abs((row - 1) - ctx.row),
              text = candidate,
            }
          else
            entry.count = entry.count + 1
            entry.distance = math.min(entry.distance, math.abs((row - 1) - ctx.row))
          end
        end
      end
    end
  end

  local best = nil
  for _, entry in pairs(candidates) do
    if not best
      or entry.count > best.count
      or (entry.count == best.count and entry.distance < best.distance)
      or (entry.count == best.count and entry.distance == best.distance and #entry.text < #best.text)
    then
      best = entry
    end
  end

  if not best then
    return nil
  end

  return {
    text = best.text,
    source = "buffer-token",
  }
end

function M.suggest(bufnr, ctx, opts)
  if not opts.local_suggestions.enabled then
    return nil
  end

  if ctx.prefix_non_space_count < opts.local_suggestions.min_chars then
    return nil
  end

  return best_line_suffix(bufnr, ctx, opts) or best_word_suffix(bufnr, ctx, opts)
end

return M
