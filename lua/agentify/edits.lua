-- Recent-edits memory. Attaches to buffers and records what the user changed (row, old
-- text, new text), coalescing consecutive edits to the same row. Feeds the completion
-- prompt as RECENT_EDITS and drives edit prediction.
local M = {
  buffers = {},
  max_shadow_lines = 20000,
}

local function now()
  return os.time()
end

local function state_for(bufnr)
  local st = M.buffers[bufnr]
  if not st then
    st = { shadow = nil, edits = {}, attached = false, suppress = 0 }
    M.buffers[bufnr] = st
  end
  return st
end

local function trim(text, max)
  if #text <= max then
    return text
  end
  return text:sub(1, max - 1) .. "…"
end

function M.record(bufnr, row, old_lines, new_lines, opts)
  local st = state_for(bufnr)
  local old = table.concat(old_lines, "\n")
  local new = table.concat(new_lines, "\n")
  if old == new then
    return
  end

  local last = st.edits[#st.edits]
  if last and last.row == row and #old_lines == 1 and #new_lines == 1 and now() - last.at <= (opts and opts.coalesce_s or 5) then
    -- keep typing on the same line: one logical edit
    last.new = new
    last.at = now()
    if last.old == last.new then
      table.remove(st.edits, #st.edits)
    end
    return
  end

  st.edits[#st.edits + 1] = { row = row, old = old, new = new, at = now() }
  local limit = opts and opts.max_edits or 8
  while #st.edits > limit do
    table.remove(st.edits, 1)
  end
end

-- Buffer-update callback (nvim_buf_attach on_lines signature).
function M.on_lines(bufnr, firstline, lastline, new_lastline, opts)
  local st = state_for(bufnr)
  if not st.shadow then
    return
  end

  if st.suppress > 0 then
    st.suppress = st.suppress - 1
    -- still keep the shadow in sync
    local fresh = vim.api.nvim_buf_get_lines(bufnr, firstline, new_lastline, false)
    for _ = firstline, lastline - 1 do
      table.remove(st.shadow, firstline + 1)
    end
    for index = #fresh, 1, -1 do
      table.insert(st.shadow, firstline + 1, fresh[index])
    end
    return
  end

  local old_lines = {}
  for index = firstline + 1, lastline do
    old_lines[#old_lines + 1] = st.shadow[index] or ""
  end
  local new_lines = vim.api.nvim_buf_get_lines(bufnr, firstline, new_lastline, false)

  -- update the shadow copy
  for _ = firstline, lastline - 1 do
    table.remove(st.shadow, firstline + 1)
  end
  for index = #new_lines, 1, -1 do
    table.insert(st.shadow, firstline + 1, new_lines[index])
  end

  M.record(bufnr, firstline, old_lines, new_lines, opts)
end

function M.attach(bufnr, opts)
  local st = state_for(bufnr)
  if st.attached then
    return true
  end

  if vim.api.nvim_buf_line_count(bufnr) > M.max_shadow_lines then
    return false
  end

  st.shadow = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  st.attached = vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, buf, _, firstline, lastline, new_lastline)
      M.on_lines(buf, firstline, lastline, new_lastline, opts)
    end,
    on_reload = function(_, buf)
      local s = M.buffers[buf]
      if s then
        s.shadow = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      end
    end,
    on_detach = function(_, buf)
      M.buffers[buf] = nil
    end,
  })

  return st.attached
end

-- Ignore the next `count` buffer changes (our own accepts).
function M.suppress_next(bufnr, count)
  local st = state_for(bufnr)
  st.suppress = st.suppress + (count or 1)
end

function M.recent(bufnr, max_age_s)
  local st = M.buffers[bufnr]
  if not st then
    return {}
  end

  local cutoff = max_age_s and (now() - max_age_s) or nil
  local result = {}
  for _, edit in ipairs(st.edits) do
    if not cutoff or edit.at >= cutoff then
      result[#result + 1] = edit
    end
  end
  return result
end

-- Lines for the prompt: "L<row>: <old>  ->  <new>", most recent last.
function M.describe(bufnr, max_entries, max_age_s)
  local edits = M.recent(bufnr, max_age_s)
  local start = math.max(1, #edits - (max_entries or 5) + 1)
  local lines = {}
  for index = start, #edits do
    local edit = edits[index]
    lines[#lines + 1] = ("L%d: %s  ->  %s"):format(
      edit.row + 1,
      trim(edit.old:gsub("\n", "⏎"), 80),
      trim(edit.new:gsub("\n", "⏎"), 80)
    )
  end
  return lines
end

function M.clear(bufnr)
  if bufnr then
    local st = M.buffers[bufnr]
    if st then
      st.edits = {}
    end
  else
    for _, st in pairs(M.buffers) do
      st.edits = {}
    end
  end
end

function M.reset()
  M.buffers = {}
end

return M
