local M = {}

M.defaults = {
  enabled = true,
  provider = "codex",
  debounce_ms = 175,
  suggestion = {
    min_chars = 3,
    highlight = "Comment",
    multiline = true,
    max_lines = 4,
    max_context_lines = {
      before = 8,
      after = 8,
    },
  },
  local_suggestions = {
    enabled = true,
    min_chars = 3,
    max_scan_lines = 400,
    max_suffix_length = 80,
  },
  lsp = {
    enabled = true,
    min_chars = 2,
    timeout_ms = 80,
    max_completion_items = 8,
    max_diagnostics = 3,
  },
  filetypes = {
    allow = {
      "bash",
      "c",
      "cpp",
      "go",
      "javascript",
      "javascriptreact",
      "json",
      "lua",
      "python",
      "rust",
      "sh",
      "toml",
      "typescript",
      "typescriptreact",
      "vim",
      "yaml",
      "zsh",
    },
    deny = {},
  },
  codex = {
    command = { "codex", "app-server" },
    model = nil,
    effort = "none",
    service_tier = nil,
    base_instructions = nil,
    refresh_account_token = false,
    warmup_on_insert = true,
  },
  logging = {
    level = "warn",
    max_entries = 200,
  },
}

local valid_log_levels = {
  error = true,
  warn = true,
  info = true,
  debug = true,
}

local function is_list(value)
  return type(value) == "table" and vim.islist(value)
end

local function merge_tables(base, override)
  if type(base) ~= "table" or type(override) ~= "table" then
    return vim.deepcopy(override)
  end

  local merged = vim.deepcopy(base)

  for key, value in pairs(override) do
    if type(value) == "table" and type(base[key]) == "table" and not is_list(value) and not is_list(base[key]) then
      merged[key] = merge_tables(base[key], value)
    else
      merged[key] = vim.deepcopy(value)
    end
  end

  return merged
end

local function expect_type(name, value, expected)
  if type(value) ~= expected then
    error(("agentify.nvim: %s must be a %s, got %s"):format(name, expected, type(value)))
  end
end

local function expect_positive_integer(name, value, allow_zero)
  expect_type(name, value, "number")

  if math.floor(value) ~= value or value < 0 or (not allow_zero and value == 0) then
    error(("agentify.nvim: %s must be a %spositive integer"):format(name, allow_zero and "non-negative " or ""))
  end
end

local function expect_string_list(name, value)
  if not is_list(value) then
    error(("agentify.nvim: %s must be a list of strings"):format(name))
  end

  for index, item in ipairs(value) do
    if type(item) ~= "string" or item == "" then
      error(("agentify.nvim: %s[%d] must be a non-empty string"):format(name, index))
    end
  end
end

local function normalize_command(command)
  if type(command) == "string" then
    return { command }
  end

  expect_string_list("codex.command", command)

  return command
end

function M.normalize(opts)
  opts = opts or {}
  expect_type("setup options", opts, "table")

  local merged = merge_tables(M.defaults, opts)

  expect_type("enabled", merged.enabled, "boolean")
  expect_type("provider", merged.provider, "string")
  expect_positive_integer("debounce_ms", merged.debounce_ms)

  expect_type("suggestion", merged.suggestion, "table")
  expect_positive_integer("suggestion.min_chars", merged.suggestion.min_chars, true)
  expect_type("suggestion.highlight", merged.suggestion.highlight, "string")
  expect_type("suggestion.multiline", merged.suggestion.multiline, "boolean")
  expect_positive_integer("suggestion.max_lines", merged.suggestion.max_lines)
  expect_type("suggestion.max_context_lines", merged.suggestion.max_context_lines, "table")
  expect_positive_integer("suggestion.max_context_lines.before", merged.suggestion.max_context_lines.before, true)
  expect_positive_integer("suggestion.max_context_lines.after", merged.suggestion.max_context_lines.after, true)

  expect_type("local_suggestions", merged.local_suggestions, "table")
  expect_type("local_suggestions.enabled", merged.local_suggestions.enabled, "boolean")
  expect_positive_integer("local_suggestions.min_chars", merged.local_suggestions.min_chars, true)
  expect_positive_integer("local_suggestions.max_scan_lines", merged.local_suggestions.max_scan_lines)
  expect_positive_integer("local_suggestions.max_suffix_length", merged.local_suggestions.max_suffix_length)

  expect_type("lsp", merged.lsp, "table")
  expect_type("lsp.enabled", merged.lsp.enabled, "boolean")
  expect_positive_integer("lsp.min_chars", merged.lsp.min_chars, true)
  expect_positive_integer("lsp.timeout_ms", merged.lsp.timeout_ms)
  expect_positive_integer("lsp.max_completion_items", merged.lsp.max_completion_items)
  expect_positive_integer("lsp.max_diagnostics", merged.lsp.max_diagnostics)

  expect_type("filetypes", merged.filetypes, "table")
  expect_string_list("filetypes.allow", merged.filetypes.allow)
  expect_string_list("filetypes.deny", merged.filetypes.deny)

  expect_type("codex", merged.codex, "table")
  merged.codex.command = normalize_command(merged.codex.command)
  if merged.codex.model ~= nil then
    expect_type("codex.model", merged.codex.model, "string")
  end
  if merged.codex.effort ~= nil then
    expect_type("codex.effort", merged.codex.effort, "string")
  end
  if merged.codex.service_tier ~= nil then
    expect_type("codex.service_tier", merged.codex.service_tier, "string")
  end
  if merged.codex.base_instructions ~= nil then
    expect_type("codex.base_instructions", merged.codex.base_instructions, "string")
  end
  expect_type("codex.refresh_account_token", merged.codex.refresh_account_token, "boolean")
  expect_type("codex.warmup_on_insert", merged.codex.warmup_on_insert, "boolean")

  expect_type("logging", merged.logging, "table")
  if not valid_log_levels[merged.logging.level] then
    error(("agentify.nvim: logging.level must be one of error, warn, info, debug; got %q"):format(tostring(merged.logging.level)))
  end
  expect_positive_integer("logging.max_entries", merged.logging.max_entries)

  return merged
end

local function contains(list, needle)
  for _, item in ipairs(list) do
    if item == needle then
      return true
    end
  end

  return false
end

function M.is_buffer_enabled(opts, bufnr)
  if not opts.enabled then
    return false, "plugin disabled"
  end

  if vim.bo[bufnr].buftype ~= "" then
    return false, "unsupported buftype"
  end

  if not vim.bo[bufnr].modifiable or vim.bo[bufnr].readonly then
    return false, "buffer is not modifiable"
  end

  local filetype = vim.bo[bufnr].filetype or ""
  if filetype == "" then
    return false, "buffer has no filetype"
  end

  if contains(opts.filetypes.deny, filetype) then
    return false, ("filetype %q is denied"):format(filetype)
  end

  if not contains(opts.filetypes.allow, filetype) then
    return false, ("filetype %q is not allowlisted"):format(filetype)
  end

  return true, ("filetype %q is enabled"):format(filetype)
end

return M
