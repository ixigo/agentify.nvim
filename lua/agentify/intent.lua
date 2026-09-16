local M = {}

local collection_words = {
  array = true,
  arrays = true,
  collection = true,
  collections = true,
  entries = true,
  elements = true,
  items = true,
  list = true,
  lists = true,
  rows = true,
  values = true,
}

local map_words = {
  dictionary = true,
  hash = true,
  map = true,
  object = true,
  payload = true,
  record = true,
}

local string_words = {
  csv = true,
  html = true,
  message = true,
  slug = true,
  string = true,
  text = true,
  title = true,
  url = true,
}

local number_words = {
  count = true,
  index = true,
  length = true,
  number = true,
  size = true,
  total = true,
}

local boolean_prefixes = {
  can = true,
  has = true,
  is = true,
  should = true,
}

local verb_hints = {
  build = "Construct a useful result from the available inputs.",
  convert = "Transform the input into the target representation.",
  create = "Create a new value using the local naming and style conventions.",
  fetch = "Retrieve or derive the requested value.",
  filter = "Keep only the values that satisfy the intent implied by the name.",
  find = "Locate the best matching value and handle the no-match case cleanly.",
  format = "Return a presentation-friendly value using the existing file style.",
  get = "Return the requested value directly and predictably.",
  load = "Load or derive the named value without unnecessary ceremony.",
  map = "Transform each input element into the desired output shape.",
  parse = "Parse the input defensively and return the derived value.",
  serialize = "Convert the input into a serializable representation.",
  sort = "Return a stable, predictable ordering.",
  stringify = "Return a string representation of the input.",
}

local definition_patterns = {
  {
    kind = "function-definition",
    pattern = "^[%s]*async%s+function%s+([%a_][%w_]*)%s*(%b())",
  },
  {
    kind = "function-definition",
    pattern = "^[%s]*function%s+([%a_][%w_]*)%s*(%b())",
  },
  {
    kind = "function-definition",
    pattern = "^[%s]*local%s+function%s+([%a_][%w_%.:]*)%s*(%b())",
  },
  {
    kind = "function-definition",
    pattern = "^[%s]*function%s+([%a_][%w_%.:]*)%s*(%b())",
  },
  {
    kind = "function-definition",
    pattern = "^[%s]*def%s+([%a_][%w_]*)%s*(%b())",
  },
  {
    kind = "function-definition",
    pattern = "^[%s]*func%s+([%a_][%w_]*)%s*(%b())",
  },
  {
    kind = "function-definition",
    pattern = "^[%s]*fn%s+([%a_][%w_]*)%s*(%b())",
  },
  {
    kind = "function-definition",
    pattern = "^[%s]*const%s+([%a_][%w_]*)%s*=%s*async%s*(%b())%s*=>",
  },
  {
    kind = "function-definition",
    pattern = "^[%s]*let%s+([%a_][%w_]*)%s*=%s*async%s*(%b())%s*=>",
  },
  {
    kind = "function-definition",
    pattern = "^[%s]*var%s+([%a_][%w_]*)%s*=%s*async%s*(%b())%s*=>",
  },
  {
    kind = "function-definition",
    pattern = "^[%s]*const%s+([%a_][%w_]*)%s*=%s*(%b())%s*=>",
  },
  {
    kind = "function-definition",
    pattern = "^[%s]*let%s+([%a_][%w_]*)%s*=%s*(%b())%s*=>",
  },
  {
    kind = "function-definition",
    pattern = "^[%s]*var%s+([%a_][%w_]*)%s*=%s*(%b())%s*=>",
  },
  {
    kind = "function-definition",
    pattern = "^[%s]*const%s+([%a_][%w_]*)%s*=%s*$",
  },
  {
    kind = "function-definition",
    pattern = "^[%s]*let%s+([%a_][%w_]*)%s*=%s*$",
  },
  {
    kind = "function-definition",
    pattern = "^[%s]*var%s+([%a_][%w_]*)%s*=%s*$",
  },
}

local function normalize_identifier(identifier)
  if type(identifier) ~= "string" or identifier == "" then
    return ""
  end

  local normalized = identifier
    :gsub("([%l%d])([%u])", "%1_%2")
    :gsub("([%u]+)([%u][%l])", "%1_%2")
    :gsub("[%-%s]+", "_")
    :lower()

  return normalized
end

local function unique_insert(list, seen, value)
  if value and value ~= "" and not seen[value] then
    seen[value] = true
    list[#list + 1] = value
  end
end

local function split_identifier(identifier)
  local words = {}
  local seen = {}
  local normalized = normalize_identifier(identifier)

  for word in normalized:gmatch("[%a][%w]*") do
    unique_insert(words, seen, word)
  end

  return words
end

local function current_symbol_fragment(prefix)
  return prefix:match("([%a_][%w_]*)$")
end

local function extract_params(param_block)
  if type(param_block) ~= "string" or param_block == "" then
    return {}
  end

  local inner = param_block:sub(2, -2)
  if inner == "" then
    return {}
  end

  local params = {}
  local seen = {}
  for raw in inner:gmatch("[^,]+") do
    local param = vim.trim(raw)
    param = param:gsub("^%.%.%.", "")
    param = param:gsub("%?.*$", "")
    param = param:gsub("%s*=.*$", "")
    param = param:gsub("%s*:.*$", "")
    param = param:gsub("^%*+", "")
    param = param:match("([%a_][%w_]*)$")
    unique_insert(params, seen, param)
  end

  return params
end

local function detect_definition(line_prefix)
  for _, entry in ipairs(definition_patterns) do
    local name, params = line_prefix:match(entry.pattern)
    if name then
      return {
        kind = entry.kind,
        name = name,
        parameters = extract_params(params),
      }
    end
  end

  return nil
end

local function return_hint(words)
  for index, word in ipairs(words) do
    if word == "to" and words[index + 1] then
      return words[index + 1]
    end
  end

  if boolean_prefixes[words[1]] then
    return "boolean"
  end

  for _, word in ipairs(words) do
    if string_words[word] then
      return "string"
    end
    if number_words[word] then
      return "number"
    end
    if collection_words[word] then
      return "collection"
    end
    if map_words[word] then
      return "map/object"
    end
  end

  return nil
end

local function input_hint(words, parameters)
  for _, name in ipairs(parameters or {}) do
    local parts = split_identifier(name)
    for _, word in ipairs(parts) do
      if collection_words[word] then
        return "collection-like input"
      end
      if map_words[word] then
        return "map/object input"
      end
      if string_words[word] then
        return "string-like input"
      end
    end
  end

  for _, word in ipairs(words or {}) do
    if collection_words[word] then
      return "collection-like input"
    end
    if map_words[word] then
      return "map/object input"
    end
  end

  return nil
end

local function operation_hint(words)
  local verb = words[1]
  if verb_hints[verb] then
    return verb_hints[verb]
  end

  if boolean_prefixes[verb] then
    return "Return a boolean answer that matches the name."
  end

  return nil
end

local function build_hints(definition, symbol_name)
  local words = split_identifier(symbol_name)
  local hints = {}

  if definition then
    hints[#hints + 1] = ("Detected %s for `%s`."):format(definition.kind, definition.name)
    if #definition.parameters > 0 then
      hints[#hints + 1] = ("Parameters: %s."):format(table.concat(definition.parameters, ", "))
    end
  else
    hints[#hints + 1] = ("Current symbol fragment: `%s`."):format(symbol_name)
  end

  local operation = operation_hint(words)
  if operation then
    hints[#hints + 1] = operation
  end

  local input = input_hint(words, definition and definition.parameters or {})
  if input then
    hints[#hints + 1] = ("Input hint: %s."):format(input)
  end

  local output = return_hint(words)
  if output then
    hints[#hints + 1] = ("Output hint: likely `%s`."):format(output)
  end

  return hints, words
end

local function searchable_buffer(bufnr, filetype, opts)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  if opts and require("agentify.config").path_denied(opts, vim.api.nvim_buf_get_name(bufnr)) then
    return false
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return false
  end

  if vim.bo[bufnr].buftype ~= "" then
    return false
  end

  if vim.bo[bufnr].filetype ~= filetype then
    return false
  end

  return true
end

local function buffer_label(bufnr, row)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local label = name ~= "" and vim.fn.fnamemodify(name, ":t") or ("buffer-%d"):format(bufnr)
  return ("[%s:%d]"):format(label, row + 1)
end

local function collect_terms(symbol_name, definition, words, opts)
  local terms = {}
  local seen = {}

  if symbol_name and #symbol_name >= opts.intent.min_symbol_chars then
    unique_insert(terms, seen, symbol_name:lower())
  end

  for _, word in ipairs(words) do
    if #word >= opts.intent.min_word_chars then
      unique_insert(terms, seen, word)
    end
    if #terms >= opts.intent.max_terms then
      break
    end
  end

  if definition then
    for _, param in ipairs(definition.parameters) do
      local lowered = normalize_identifier(param)
      if #lowered >= opts.intent.min_word_chars then
        unique_insert(terms, seen, lowered)
      end

      if #terms >= opts.intent.max_terms then
        break
      end
    end
  end

  return terms
end

local function matching_term_count(line, lowered_terms)
  local lowered = line:lower()
  local count = 0

  for _, term in ipairs(lowered_terms) do
    if lowered:find(term, 1, true) then
      count = count + 1
    end
  end

  return count
end

local function trim_line(line)
  line = vim.trim(line)
  if #line <= 140 then
    return line
  end

  return line:sub(1, 137) .. "..."
end

local function collect_related_lines(bufnr, ctx, intent, opts)
  local terms = collect_terms(intent.symbol_name, intent.definition, intent.words, opts)
  if #terms == 0 then
    return {}
  end

  local candidates = {}
  local seen = {}
  local buffers = { bufnr }

  for _, candidate_bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if candidate_bufnr ~= bufnr and searchable_buffer(candidate_bufnr, ctx.filetype, opts) then
      buffers[#buffers + 1] = candidate_bufnr
      if #buffers >= opts.intent.max_open_buffers then
        break
      end
    end
  end

  for _, candidate_bufnr in ipairs(buffers) do
    local lines = vim.api.nvim_buf_get_lines(candidate_bufnr, 0, -1, false)
    for row, line in ipairs(lines) do
      local row_index = row - 1
      if line:match("%S") then
        local is_current_row = candidate_bufnr == bufnr and row_index == ctx.row
        local nearby_current_line = candidate_bufnr == bufnr
          and math.abs(row_index - ctx.row) <= math.max(opts.suggestion.max_context_lines.before, opts.suggestion.max_context_lines.after)
        if not is_current_row and not nearby_current_line then
          local match_count = matching_term_count(line, terms)
          if match_count > 0 then
            local text = trim_line(line)
            local key = ("%d:%s"):format(candidate_bufnr, text)
            if not seen[key] then
              seen[key] = true
              local score = match_count * 100
              if candidate_bufnr == bufnr then
                score = score + 30 - math.min(30, math.abs(row_index - ctx.row))
              end
              if text:find("return", 1, true) then
                score = score + 15
              end
              candidates[#candidates + 1] = {
                score = score,
                text = ("%s %s"):format(buffer_label(candidate_bufnr, row_index), text),
              }
            end
          end
        end
      end
    end
  end

  table.sort(candidates, function(left, right)
    if left.score == right.score then
      return left.text < right.text
    end
    return left.score > right.score
  end)

  local lines = {}
  for index = 1, math.min(#candidates, opts.intent.max_related_lines) do
    lines[#lines + 1] = candidates[index].text
  end

  return lines
end

function M.analyze(bufnr, ctx, opts)
  if not opts.intent.enabled then
    return nil
  end

  local definition = detect_definition(ctx.line_prefix)
  local symbol_name = definition and definition.name or current_symbol_fragment(ctx.line_prefix)
  if not symbol_name or #symbol_name < opts.intent.min_symbol_chars then
    return nil
  end

  local hints, words = build_hints(definition, symbol_name)
  local semantic_definition = definition ~= nil
    and (#words >= 2 or operation_hint(words) ~= nil or return_hint(words) ~= nil or #(definition.parameters or {}) > 0)
  local intent = {
    kind = definition and definition.kind or "symbol-completion",
    symbol_name = symbol_name,
    parameters = definition and definition.parameters or {},
    hints = hints,
    words = words,
    definition = definition,
    prefer_provider = semantic_definition,
  }

  intent.related_lines = collect_related_lines(bufnr, ctx, intent, opts)
  return intent
end

function M.prefers_provider(ctx)
  return ctx.intent ~= nil and ctx.intent.prefer_provider == true
end

function M.should_continue_provider(ctx, fast_completion)
  return M.prefers_provider(ctx) and fast_completion ~= nil and fast_completion.provisional == true
end

return M
