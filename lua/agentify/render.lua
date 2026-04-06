local state = require("agentify.state")

local M = {}
local namespace = vim.api.nvim_create_namespace("agentify.nvim")

function M.show(bufnr, suggestion, opts)
  local buffer_state = state.get_buffer(bufnr)
  local lines = vim.split(suggestion.text, "\n", { plain = true, trimempty = false })
  local params = {
    id = buffer_state.extmark_id,
    hl_mode = "combine",
    strict = false,
  }

  if lines[1] ~= "" then
    params.virt_text = { { lines[1], opts.suggestion.highlight } }
    params.virt_text_pos = "inline"
  end

  if #lines > 1 then
    params.virt_lines = {}
    for index = 2, #lines do
      params.virt_lines[#params.virt_lines + 1] = {
        { lines[index], opts.suggestion.highlight },
      }
    end
  end

  buffer_state.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, namespace, suggestion.row, suggestion.col, params)
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
