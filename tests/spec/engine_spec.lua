local context = require("agentify.context")
local engine = require("agentify.engine")
local h = require("tests.helpers")

return {
  {
    name = "enforces the automatic trigger threshold",
    fn = function()
      local opts = {
        suggestion = {
          min_chars = 3,
        },
      }

      h.eq(false, engine.should_auto_trigger({
        prefix_non_space_count = 2,
        line_prefix = "ab",
        line_suffix = "",
      }, opts))

      h.eq(true, engine.should_auto_trigger({
        prefix_non_space_count = 3,
        line_prefix = "abc",
        line_suffix = "",
      }, opts))
    end,
  },
  {
    name = "marks changed snapshots as stale",
    fn = function()
      h.with_buffer({ "local value = 1" }, function(bufnr)
        vim.bo[bufnr].filetype = "lua"
        vim.api.nvim_win_set_cursor(0, { 1, #"local value = 1" })

        local original_get_mode = vim.api.nvim_get_mode
        vim.api.nvim_get_mode = function()
          return { mode = "i" }
        end

        local ctx = context.build(bufnr, {
          suggestion = {
            max_context_lines = { before = 1, after = 1 },
          },
        })

        local snapshot = context.snapshot(ctx)
        h.eq(false, engine.is_snapshot_stale(snapshot))

        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "local value = 2" })
        h.eq(true, engine.is_snapshot_stale(snapshot))

        vim.api.nvim_get_mode = original_get_mode
      end)
    end,
  },
}
