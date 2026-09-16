-- Small per-buffer memory of recently shown suggestions, keyed by the exact cursor
-- context (row, line prefix, line suffix). Lets backspacing into a prefix that already
-- had a suggestion re-show it instantly without asking the provider again.
local M = {
  buffers = {},
}

function M.key(row, prefix, suffix)
  return ("%d\0%s\0%s"):format(row, prefix, suffix)
end

local function entries(bufnr)
  local list = M.buffers[bufnr]
  if not list then
    list = {}
    M.buffers[bufnr] = list
  end
  return list
end

local function remove(list, key)
  for index, entry in ipairs(list) do
    if entry.key == key then
      table.remove(list, index)
      return entry
    end
  end
  return nil
end

function M.remember(bufnr, key, text, max_entries)
  if type(text) ~= "string" or text == "" then
    return
  end

  local list = entries(bufnr)
  remove(list, key)
  table.insert(list, 1, { key = key, text = text })

  local limit = max_entries or 16
  while #list > limit do
    table.remove(list, #list)
  end
end

function M.lookup(bufnr, key)
  local list = M.buffers[bufnr]
  if not list then
    return nil
  end

  local entry = remove(list, key)
  if not entry then
    return nil
  end

  table.insert(list, 1, entry)
  return entry.text
end

function M.forget(bufnr, key)
  local list = M.buffers[bufnr]
  if list then
    remove(list, key)
  end
end

function M.clear(bufnr)
  if bufnr then
    M.buffers[bufnr] = nil
  else
    M.buffers = {}
  end
end

function M.count(bufnr)
  local list = M.buffers[bufnr]
  return list and #list or 0
end

return M
