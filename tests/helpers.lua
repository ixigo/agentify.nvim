local M = {}

local function fail(message)
  error(message, 2)
end

function M.eq(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    fail((message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))
  end
end

function M.ok(value, message)
  if not value then
    fail(message or "expected truthy value")
  end
end

function M.match(pattern, text, message)
  if not tostring(text):match(pattern) then
    fail((message or "pattern did not match") .. "\npattern: " .. pattern .. "\ntext: " .. tostring(text))
  end
end

function M.with_buffer(lines, callback)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  local ok, result = xpcall(function()
    return callback(bufnr)
  end, debug.traceback)

  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end

  if not ok then
    error(result, 0)
  end

  return result
end

return M
