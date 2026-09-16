local M = {}

M.defaults = {
  enabled = true,
  provider = "auto",
  frontend = "extmark",
  warmup_on_insert = true,
  debounce_ms = 175,
  -- Used instead of debounce_ms while a provider request is already in flight, so a
  -- burst of keystrokes does not turn into a burst of interrupted model turns.
  debounce_busy_ms = 320,
  -- Typing the characters of the visible ghost text shortens it instead of dismissing it.
  type_through = true,
  -- Request the next suggestion right after a full accept instead of waiting for a keystroke.
  prefetch_after_accept = true,
  recall = {
    -- Re-show a recent suggestion instantly when backspacing into a prefix that had one.
    enabled = true,
    max_entries = 16,
  },
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
  intent = {
    enabled = true,
    min_symbol_chars = 3,
    min_word_chars = 3,
    max_terms = 6,
    max_open_buffers = 4,
    max_related_lines = 8,
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
  edits = {
    -- Remember what the user recently changed; shown to the model as RECENT_EDITS.
    enabled = true,
    max_edits = 8,
    max_age_s = 180,
    prompt_entries = 5,
    coalesce_s = 5,
  },
  edit_prediction = {
    -- After an edit, ask the model for the most likely follow-up edit elsewhere in the
    -- window and show it as strikethrough old text plus ghost new text.
    enabled = true,
    idle_ms = 600,
    window_lines = 30,
    -- Only predict when the last edit is this recent.
    max_edit_age_s = 60,
    in_insert = true,
    hint = "accept edit",
  },
  jump = {
    -- After an accept, hint at the likely next edit (nearest diagnostic below the cursor,
    -- or a TODO / empty body / empty block). Model-free.
    enabled = true,
    max_distance = 40,
    diagnostics = true,
    max_severity = vim.diagnostic.severity.WARN,
    placeholders = true,
    highlight = "DiagnosticVirtualTextHint",
  },
  repo_context = {
    -- Pull definitions and call sites for identifiers near the cursor from the local
    -- Agentify index (`agentify scan`) into the model prompt.
    enabled = true,
    command = { "agentify" },
    max_symbols = 2,
    min_symbol_chars = 3,
    max_definition_lines = 24,
    max_reference_lines = 4,
    -- How long a request waits for index lookups before going ahead without them.
    timeout_ms = 250,
    process_timeout_ms = 4000,
    cache_ttl_s = 120,
    max_cache_entries = 64,
  },
  agent = {
    -- :AgentifyFix and :AgentifyExplain run a fresh `claude -p` with tools in the project
    -- root. They bypass the hourly budget (they are deliberate) but respect a cooldown.
    model = "sonnet",
    effort = "medium",
    max_turns = 12,
    panel_height = 12,
    fix = { tools = { "Read", "Edit", "Grep", "Glob" } },
    explain = { tools = { "Read", "Grep", "Glob" } },
    extra_args = {},
  },
  budget = {
    -- Model requests allowed per rolling hour across all buffers; 0 disables the cap.
    -- Fast (local) suggestions keep working when the cap is reached.
    max_requests_per_hour = 300,
    -- Pause the model tier for this long after a provider reports a rate limit.
    rate_limit_cooldown_s = 300,
    -- Never call the model automatically; only `:AgentifySuggest` reaches it.
    fast_only = false,
    -- Show a one-time notification when the model tier is paused.
    notify = true,
  },
  paths = {
    -- Lua patterns matched (case-insensitively) against the full buffer path. Matching
    -- buffers get no suggestions and are never used as context for other buffers.
    deny = {
      "%.env$",
      "%.env%.",
      "/secrets?/",
      "%.pem$",
      "%.key$",
      "%.p12$",
      "%.pfx$",
      "%.kdbx$",
      "id_rsa",
      "id_ed25519",
      "credentials",
      "/%.aws/",
      "/%.ssh/",
      "/%.gnupg/",
    },
  },
  auth = {
    -- Only use hour-based subscription sessions (claude.ai login, ChatGPT login).
    -- API-key billing is refused and API-key environment variables are stripped
    -- from every CLI process the plugin spawns.
    subscription_only = true,
    strip_env = { "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY" },
  },
  providers = {
    codex = {
      command = { "codex", "app-server" },
      model = nil,
      effort = "none",
      service_tier = nil,
      base_instructions = nil,
      refresh_account_token = false,
    },
    claude = {
      command = { "claude" },
      model = "haiku",
      manual_model = "sonnet",
      effort = "low",
      max_session_turns = 40,
      min_version = "2.0.0",
      extra_args = {},
      base_instructions = nil,
    },
  },
  logging = {
    level = "warn",
    max_entries = 200,
  },
}

M.provider_names = { "claude", "codex" }

local valid_log_levels = {
  error = true,
  warn = true,
  info = true,
  debug = true,
}

local valid_providers = {
  auto = true,
  codex = true,
  claude = true,
}

local valid_frontends = {
  extmark = true,
  lsp = true,
}

local function is_list(value)
  return type(value) == "table" and vim.islist(value)
end

local function is_empty(value)
  return type(value) == "table" and next(value) == nil
end

-- Deep-merges dict-like tables; list-like values replace the default outright.
-- An empty override table against a dict default (e.g. `budget = {}`) keeps the defaults,
-- while against a list default (e.g. `paths = { deny = {} }`) it clears the list.
local function merge_tables(base, override)
  if type(base) ~= "table" or type(override) ~= "table" then
    return vim.deepcopy(override)
  end

  local merged = vim.deepcopy(base)

  for key, value in pairs(override) do
    local base_value = base[key]
    local base_is_dict = type(base_value) == "table" and not is_list(base_value)
    if type(value) == "table" and base_is_dict and (is_empty(value) or not is_list(value)) then
      merged[key] = merge_tables(base_value, value)
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

local function expect_optional_string(name, value)
  if value ~= nil then
    expect_type(name, value, "string")
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

local function normalize_command(name, command)
  if type(command) == "string" then
    return { command }
  end

  expect_string_list(name, command)

  if #command == 0 then
    error(("agentify.nvim: %s must not be empty"):format(name))
  end

  return command
end

-- Older configs put Codex options under a top-level `codex` table. Fold them into
-- `providers.codex` and lift `codex.warmup_on_insert` to the top level.
local function migrate_legacy(opts)
  local deprecations = {}

  if type(opts.codex) ~= "table" then
    return opts, deprecations
  end

  opts = vim.deepcopy(opts)
  local legacy = opts.codex
  opts.codex = nil
  opts.providers = opts.providers or {}
  opts.providers.codex = opts.providers.codex or {}

  for key, value in pairs(legacy) do
    if key == "warmup_on_insert" then
      if opts.warmup_on_insert == nil then
        opts.warmup_on_insert = value
      end
    elseif opts.providers.codex[key] == nil then
      opts.providers.codex[key] = value
    end
  end

  table.insert(
    deprecations,
    "`codex = {...}` moved to `providers.codex = {...}`; `codex.warmup_on_insert` is now top-level `warmup_on_insert`."
  )

  return opts, deprecations
end

local function validate_codex(codex)
  expect_type("providers.codex", codex, "table")
  codex.command = normalize_command("providers.codex.command", codex.command)
  expect_optional_string("providers.codex.model", codex.model)
  expect_optional_string("providers.codex.effort", codex.effort)
  expect_optional_string("providers.codex.service_tier", codex.service_tier)
  expect_optional_string("providers.codex.base_instructions", codex.base_instructions)
  expect_type("providers.codex.refresh_account_token", codex.refresh_account_token, "boolean")
end

local function validate_claude(claude)
  expect_type("providers.claude", claude, "table")
  claude.command = normalize_command("providers.claude.command", claude.command)
  expect_type("providers.claude.model", claude.model, "string")
  expect_optional_string("providers.claude.manual_model", claude.manual_model)
  expect_optional_string("providers.claude.effort", claude.effort)
  expect_positive_integer("providers.claude.max_session_turns", claude.max_session_turns)
  expect_type("providers.claude.min_version", claude.min_version, "string")
  expect_string_list("providers.claude.extra_args", claude.extra_args)
  expect_optional_string("providers.claude.base_instructions", claude.base_instructions)
end

function M.normalize(opts)
  opts = opts or {}
  expect_type("setup options", opts, "table")

  local deprecations
  opts, deprecations = migrate_legacy(opts)

  local merged = merge_tables(M.defaults, opts)

  expect_type("enabled", merged.enabled, "boolean")
  expect_type("provider", merged.provider, "string")
  if not valid_providers[merged.provider] then
    error(("agentify.nvim: provider must be one of auto, claude, codex; got %q"):format(tostring(merged.provider)))
  end
  expect_type("frontend", merged.frontend, "string")
  if not valid_frontends[merged.frontend] then
    error(("agentify.nvim: frontend must be one of extmark, lsp; got %q"):format(tostring(merged.frontend)))
  end
  expect_type("warmup_on_insert", merged.warmup_on_insert, "boolean")
  expect_positive_integer("debounce_ms", merged.debounce_ms)
  expect_positive_integer("debounce_busy_ms", merged.debounce_busy_ms)
  expect_type("type_through", merged.type_through, "boolean")
  expect_type("prefetch_after_accept", merged.prefetch_after_accept, "boolean")
  expect_type("recall", merged.recall, "table")
  expect_type("recall.enabled", merged.recall.enabled, "boolean")
  expect_positive_integer("recall.max_entries", merged.recall.max_entries)

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

  expect_type("intent", merged.intent, "table")
  expect_type("intent.enabled", merged.intent.enabled, "boolean")
  expect_positive_integer("intent.min_symbol_chars", merged.intent.min_symbol_chars, true)
  expect_positive_integer("intent.min_word_chars", merged.intent.min_word_chars, true)
  expect_positive_integer("intent.max_terms", merged.intent.max_terms)
  expect_positive_integer("intent.max_open_buffers", merged.intent.max_open_buffers)
  expect_positive_integer("intent.max_related_lines", merged.intent.max_related_lines)

  expect_type("filetypes", merged.filetypes, "table")
  expect_string_list("filetypes.allow", merged.filetypes.allow)
  expect_string_list("filetypes.deny", merged.filetypes.deny)

  expect_type("edits", merged.edits, "table")
  expect_type("edits.enabled", merged.edits.enabled, "boolean")
  expect_positive_integer("edits.max_edits", merged.edits.max_edits)
  expect_positive_integer("edits.max_age_s", merged.edits.max_age_s)
  expect_positive_integer("edits.prompt_entries", merged.edits.prompt_entries)
  expect_positive_integer("edits.coalesce_s", merged.edits.coalesce_s, true)

  expect_type("edit_prediction", merged.edit_prediction, "table")
  expect_type("edit_prediction.enabled", merged.edit_prediction.enabled, "boolean")
  expect_positive_integer("edit_prediction.idle_ms", merged.edit_prediction.idle_ms)
  expect_positive_integer("edit_prediction.window_lines", merged.edit_prediction.window_lines)
  expect_positive_integer("edit_prediction.max_edit_age_s", merged.edit_prediction.max_edit_age_s)
  expect_type("edit_prediction.in_insert", merged.edit_prediction.in_insert, "boolean")
  expect_type("edit_prediction.hint", merged.edit_prediction.hint, "string")

  expect_type("jump", merged.jump, "table")
  expect_type("jump.enabled", merged.jump.enabled, "boolean")
  expect_positive_integer("jump.max_distance", merged.jump.max_distance)
  expect_type("jump.diagnostics", merged.jump.diagnostics, "boolean")
  expect_positive_integer("jump.max_severity", merged.jump.max_severity)
  expect_type("jump.placeholders", merged.jump.placeholders, "boolean")
  expect_type("jump.highlight", merged.jump.highlight, "string")

  expect_type("repo_context", merged.repo_context, "table")
  expect_type("repo_context.enabled", merged.repo_context.enabled, "boolean")
  merged.repo_context.command = normalize_command("repo_context.command", merged.repo_context.command)
  expect_positive_integer("repo_context.max_symbols", merged.repo_context.max_symbols)
  expect_positive_integer("repo_context.min_symbol_chars", merged.repo_context.min_symbol_chars)
  expect_positive_integer("repo_context.max_definition_lines", merged.repo_context.max_definition_lines)
  expect_positive_integer("repo_context.max_reference_lines", merged.repo_context.max_reference_lines, true)
  expect_positive_integer("repo_context.timeout_ms", merged.repo_context.timeout_ms)
  expect_positive_integer("repo_context.process_timeout_ms", merged.repo_context.process_timeout_ms)
  expect_positive_integer("repo_context.cache_ttl_s", merged.repo_context.cache_ttl_s)
  expect_positive_integer("repo_context.max_cache_entries", merged.repo_context.max_cache_entries)

  expect_type("agent", merged.agent, "table")
  expect_type("agent.model", merged.agent.model, "string")
  expect_optional_string("agent.effort", merged.agent.effort)
  expect_positive_integer("agent.max_turns", merged.agent.max_turns)
  expect_positive_integer("agent.panel_height", merged.agent.panel_height)
  expect_type("agent.fix", merged.agent.fix, "table")
  expect_string_list("agent.fix.tools", merged.agent.fix.tools)
  expect_type("agent.explain", merged.agent.explain, "table")
  expect_string_list("agent.explain.tools", merged.agent.explain.tools)
  expect_string_list("agent.extra_args", merged.agent.extra_args)

  expect_type("budget", merged.budget, "table")
  expect_positive_integer("budget.max_requests_per_hour", merged.budget.max_requests_per_hour, true)
  expect_positive_integer("budget.rate_limit_cooldown_s", merged.budget.rate_limit_cooldown_s, true)
  expect_type("budget.fast_only", merged.budget.fast_only, "boolean")
  expect_type("budget.notify", merged.budget.notify, "boolean")

  expect_type("paths", merged.paths, "table")
  expect_string_list("paths.deny", merged.paths.deny)

  expect_type("auth", merged.auth, "table")
  expect_type("auth.subscription_only", merged.auth.subscription_only, "boolean")
  expect_string_list("auth.strip_env", merged.auth.strip_env)

  expect_type("providers", merged.providers, "table")
  validate_codex(merged.providers.codex)
  validate_claude(merged.providers.claude)

  expect_type("logging", merged.logging, "table")
  if not valid_log_levels[merged.logging.level] then
    error(("agentify.nvim: logging.level must be one of error, warn, info, debug; got %q"):format(tostring(merged.logging.level)))
  end
  expect_positive_integer("logging.max_entries", merged.logging.max_entries)

  merged.deprecations = deprecations

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

-- True when `path` matches any `paths.deny` pattern.
function M.path_denied(opts, path)
  if type(path) ~= "string" or path == "" or not opts.paths then
    return false
  end

  local lowered = path:lower()
  for _, pattern in ipairs(opts.paths.deny or {}) do
    local ok, found = pcall(string.find, lowered, pattern:lower())
    if ok and found then
      return true, pattern
    end
  end

  return false
end

function M.is_buffer_enabled(opts, bufnr)
  if not opts.enabled then
    return false, "plugin disabled"
  end

  local denied, pattern = M.path_denied(opts, vim.api.nvim_buf_get_name(bufnr))
  if denied then
    return false, ("path matches paths.deny (%s)"):format(pattern)
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
