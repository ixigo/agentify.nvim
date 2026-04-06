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

function M.base_instructions(user_override)
  local lines = {
    "You power a Neovim inline autocomplete feature.",
    "Return only the exact text that should be inserted at the cursor.",
    "Return a single line only.",
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

function M.build_completion_request(context)
  local lines = {
    "Complete the current line at the cursor.",
    "Reply with completion text only.",
    "Single line only.",
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
    "",
    "Return only the text to insert at the cursor.",
  }

  return table.concat(lines, "\n")
end

return M
