local M = {}

local js_like_filetypes = {
  javascript = true,
  javascriptreact = true,
  typescript = true,
  typescriptreact = true,
}

local print_like_filetypes = {
  python = "print",
  lua = "print",
}

local declaration_patterns = {
  "^[%s]*const%s+([%a_][%w_]*)%s*=",
  "^[%s]*let%s+([%a_][%w_]*)%s*=",
  "^[%s]*let%s+mut%s+([%a_][%w_]*)%s*=",
  "^[%s]*var%s+([%a_][%w_]*)%s*=",
  "^[%s]*local%s+([%a_][%w_]*)%s*=",
  "^[%s]*([%a_][%w_]*)%s*:=",
  "^[%s]*([%a_][%w_]*)%s*=",
  "^[%s]*const%s+{%s*([%a_][%w_]*)",
  "^[%s]*let%s+{%s*([%a_][%w_]*)",
  "^[%s]*var%s+{%s*([%a_][%w_]*)",
  "^[%s]*const%s+%[%s*([%a_][%w_]*)",
  "^[%s]*let%s+%[%s*([%a_][%w_]*)",
  "^[%s]*var%s+%[%s*([%a_][%w_]*)",
  "^[%s]*async%s+function%s+([%a_][%w_]*)%s*%(",
  "^[%s]*function%s+([%a_][%w_]*)%s*%(",
  "^[%s]*class%s+([%a_][%w_]*)%s*[{<:]?",
}

local function indent_unit(ctx)
  if not ctx.expandtab then
    return "\t"
  end

  local width = ctx.shiftwidth > 0 and ctx.shiftwidth or ctx.tabstop
  return string.rep(" ", width)
end

local function block_template(ctx, leading)
  local indent = ctx.line_prefix:match("^(%s*)") or ""
  local inner_indent = indent .. indent_unit(ctx)
  return leading .. "{\n" .. inner_indent .. "\n" .. indent .. "}"
end

local function arrow_function_template(ctx)
  if not js_like_filetypes[ctx.filetype] or ctx.line_suffix ~= "" then
    return nil
  end

  if not ctx.line_prefix:match("=>%s*$") then
    return nil
  end

  local leading = ctx.line_prefix:match("%s$") and "" or " "
  return {
    text = block_template(ctx, leading),
    source = "template-arrow-function",
    reason = "template-suggestion",
  }
end

local function nearest_non_empty_line(ctx)
  for index = #ctx.before_lines, 1, -1 do
    local line = ctx.before_lines[index]
    if line:match("%S") then
      return line
    end
  end

  return nil
end

local function wants_semicolon(ctx)
  local line = nearest_non_empty_line(ctx)
  if not line then
    return false
  end

  return line:match(";%s*$") ~= nil
end

local function inferred_identifier(ctx)
  for index = #ctx.before_lines, 1, -1 do
    local line = ctx.before_lines[index]
    for _, pattern in ipairs(declaration_patterns) do
      local identifier = line:match(pattern)
      if identifier then
        return identifier
      end
    end
  end

  return nil
end

local function console_log_template(ctx)
  if not js_like_filetypes[ctx.filetype] or ctx.line_suffix ~= "" then
    return nil
  end

  local exact_console = ctx.line_prefix:match("^%s*console%s*$")
  local exact_console_log = ctx.line_prefix:match("^%s*console%.log%s*$")
  if not exact_console and not exact_console_log then
    return nil
  end

  local indent = ctx.line_prefix:match("^(%s*)") or ""
  local identifier = inferred_identifier(ctx)
  local args = identifier and ('"%s", %s'):format(identifier, identifier) or ""
  local statement = indent .. "console.log(" .. args .. ")" .. (wants_semicolon(ctx) and ";" or "")

  if not vim.startswith(statement, ctx.line_prefix) then
    return nil
  end

  return {
    text = statement:sub(#ctx.line_prefix + 1),
    source = "template-console-log",
    reason = "template-suggestion",
  }
end

local function print_template(ctx)
  local callee = print_like_filetypes[ctx.filetype]
  if not callee or ctx.line_suffix ~= "" then
    return nil
  end

  if not ctx.line_prefix:match("^%s*" .. callee .. "%s*$") then
    return nil
  end

  local indent = ctx.line_prefix:match("^(%s*)") or ""
  local identifier = inferred_identifier(ctx)
  local args = identifier and ('"%s", %s'):format(identifier, identifier) or ""
  local statement = indent .. callee .. "(" .. args .. ")"

  if not vim.startswith(statement, ctx.line_prefix) then
    return nil
  end

  return {
    text = statement:sub(#ctx.line_prefix + 1),
    source = "template-print-debug",
    reason = "template-suggestion",
  }
end

function M.suggest(ctx, opts)
  if not js_like_filetypes[ctx.filetype] and not print_like_filetypes[ctx.filetype] then
    return nil
  end

  return console_log_template(ctx)
    or print_template(ctx)
    or (opts.suggestion.multiline and arrow_function_template(ctx) or nil)
end

return M
