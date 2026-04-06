local state = require("agentify.state")

local M = {}
local namespace = vim.api.nvim_create_namespace("agentify.nvim")

function M.show(bufnr, suggestion, opts)
  local buffer_state = state.get_buffer(bufnr)

  buffer_state.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, namespace, suggestion.row, suggestion.col, {
    id = buffer_state.extmark_id,
    virt_text = { { suggestion.text, opts.suggestion.highlight } },
    virt_text_pos = "inline",
    hl_mode = "combine",
    strict = false,
  })
end

function M.clear(bufnr)
  local buffer_state = state.get_buffer(bufnr)
  if not buffer_state.extmark_id then
    return
  end

  pcall(vim.api.nvim_buf_del_extmark, bufnr, namespace, buffer_state.extmark_id)
  buffer_state.extmark_id = nil
end

return M

