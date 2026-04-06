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
  {
    name = "accepts a multiline suggestion",
    fn = function()
      h.with_buffer({ "if ready then" }, function(bufnr)
        state.get_buffer(bufnr).suggestion = {
          bufnr = bufnr,
          row = 0,
          col = #"if ready then",
          text = "\n  return value\nend",
        }

        h.ok(actions.accept(bufnr))
        h.eq({ "if ready then", "  return value", "end" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
        h.eq({ 3, 2 }, vim.api.nvim_win_get_cursor(0))
      end)
    end,
  },
}
