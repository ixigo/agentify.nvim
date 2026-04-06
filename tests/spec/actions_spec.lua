local actions = require("agentify.actions")
local h = require("tests.helpers")
local state = require("agentify.state")

return {
  {
    name = "accepts a full suggestion",
    fn = function()
      h.with_buffer({ "return " }, function(bufnr)
        state.get_buffer(bufnr).suggestion = {
          bufnr = bufnr,
          row = 0,
          col = 7,
          text = "value",
        }

        h.ok(actions.accept(bufnr))
        h.eq("return value", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
      end)
    end,
  },
  {
    name = "accepts the next word fragment",
    fn = function()
      h.with_buffer({ "return " }, function(bufnr)
        state.get_buffer(bufnr).suggestion = {
          bufnr = bufnr,
          row = 0,
          col = 7,
          text = "value + rest",
        }

        h.ok(actions.accept_word(bufnr))
        h.eq("return value ", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
      end)
    end,
  },
  {
    name = "dismisses the current suggestion",
    fn = function()
      h.with_buffer({ "return " }, function(bufnr)
        state.get_buffer(bufnr).suggestion = {
          bufnr = bufnr,
          row = 0,
          col = 7,
          text = "value",
        }

        actions.dismiss(bufnr)
        h.eq(nil, state.get_buffer(bufnr).suggestion)
      end)
    end,
  },
}

