local M = {}

local function block(label, lines)
  if type(lines) == "table" then
    if #lines == 0 then
      return label .. ":\n<empty>"
    end

    return label .. ":\n" .. table.concat(lines, "\n")
  end

  if lines == "" or lines == nil then
    return label .. ":\n<empty>"
  end

  return label .. ":\n" .. tostring(lines)
end

function M.base_instructions(opts)
  local user_override = opts.codex.base_instructions
  local lines = {
    "You power a Neovim inline autocomplete feature.",
    "Return only the exact text that should be inserted at the cursor.",
    ("Return at most %d lines."):format(opts.suggestion.max_lines),
    "Do not wrap the answer in markdown, quotes, or code fences.",
    "Do not explain your choice.",
    "Do not produce plans, reasoning, or analysis.",
    "Do not use tools or access files outside the supplied context.",
    "If there is no confident completion, return an empty string.",
  }

  if user_override and user_override ~= "" then
    table.insert(lines, user_override)
  end

  return table.concat(lines, "\n")
end

function M.build_completion_request(context, opts)
  local multiline_allowed = opts.suggestion.multiline and context.line_suffix == ""
  local lines = {
    multiline_allowed and "Complete from the cursor and you may continue onto the next lines."
      or "Complete the current line at the cursor.",
    "Reply with completion text only.",
    multiline_allowed and ("You may return up to %d lines."):format(opts.suggestion.max_lines) or "Single line only.",
    "",
    ("FILEPATH: %s"):format(context.filepath ~= "" and context.filepath or "[No Name]"),
    ("FILETYPE: %s"):format(context.filetype ~= "" and context.filetype or "plain"),
    ("INDENT_STYLE: %s"):format(context.expandtab and "spaces" or "tabs"),
    ("TABSTOP: %d"):format(context.tabstop),
    ("SHIFTWIDTH: %d"):format(context.shiftwidth),
    "",
    block("NEARBY_LINES_BEFORE", context.before_lines),
    block("CURRENT_LINE_PREFIX", context.line_prefix),
    block("CURRENT_LINE_SUFFIX", context.line_suffix),
    block("NEARBY_LINES_AFTER", context.after_lines),
  }

  if context.lsp then
    lines[#lines + 1] = ""
    lines[#lines + 1] = block("ATTACHED_LSP_CLIENTS", context.lsp.clients)
    lines[#lines + 1] = block("CURRENT_LINE_DIAGNOSTICS", context.lsp.diagnostics)
    if context.lsp.completions then
      lines[#lines + 1] = block("LSP_COMPLETION_CANDIDATES", context.lsp.completions)
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = multiline_allowed
      and "Return only the text to insert at the cursor. Do not repeat existing suffix text from later lines."
      or "Return only the text to insert at the cursor."

  return table.concat(lines, "\n")
end

return M
