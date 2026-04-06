local M = {
  buffers = {},
}

local function close_timer(timer)
  if not timer then
    return
  end

  timer:stop()

  if not timer:is_closing() then
    timer:close()
  end
end

function M.get_buffer(bufnr)
  if bufnr == 0 or bufnr == nil then
    bufnr = vim.api.nvim_get_current_buf()
  end

  if not M.buffers[bufnr] then
    M.buffers[bufnr] = {
      request_seq = 0,
      active_request = nil,
      suggestion = nil,
      extmark_id = nil,
      timer = nil,
      suppress_text_changed = false,
      last_error = nil,
    }
  end

  return M.buffers[bufnr]
end

function M.next_request(bufnr)
  local buffer_state = M.get_buffer(bufnr)
  buffer_state.request_seq = buffer_state.request_seq + 1
  return buffer_state.request_seq
end

function M.clear_suggestion(bufnr)
  local buffer_state = M.get_buffer(bufnr)
  buffer_state.suggestion = nil
  buffer_state.extmark_id = nil
end

function M.destroy_buffer(bufnr)
  local buffer_state = M.buffers[bufnr]
  if not buffer_state then
    return
  end

  close_timer(buffer_state.timer)
  M.buffers[bufnr] = nil
end

function M.reset()
  for bufnr, _ in pairs(M.buffers) do
    M.destroy_buffer(bufnr)
  end

  M.buffers = {}
end

return M

