local config = require("agentify.config")
local context = require("agentify.context")
local h = require("tests.helpers")
local intent = require("agentify.intent")

return {
  {
    name = "analyzes function intent and related open buffer lines",
    fn = function()
      local peer = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(peer, 0, -1, false, {
        "export function joinArray(array: string[]) {",
        '  const stringValue = array.join(", ");',
        "  return stringValue;",
        "}",
      })
      vim.bo[peer].filetype = "typescript"

      local ok, result = xpcall(function()
        h.with_buffer({
          "const convertArrayToString = (items) =>",
        }, function(bufnr)
          vim.bo[bufnr].filetype = "typescript"
          vim.cmd("startinsert")
          vim.api.nvim_win_set_cursor(0, { 1, #"const convertArrayToString = (items) =>" })

          local opts = config.normalize({})
          local ctx = context.build(bufnr, opts)
          local info = intent.analyze(bufnr, ctx, opts)

          h.ok(info)
          h.eq("function-definition", info.kind)
          h.eq("convertArrayToString", info.symbol_name)
          h.eq({ "items" }, info.parameters)
          h.eq(true, info.prefer_provider)
          h.match("Output hint: likely `string`", table.concat(info.hints, "\n"))
          h.match("joinArray", table.concat(info.related_lines, "\n"))
        end)
      end, debug.traceback)

      if vim.api.nvim_buf_is_valid(peer) then
        vim.api.nvim_buf_delete(peer, { force = true })
      end

      if not ok then
        error(result, 0)
      end
    end,
  },
}
