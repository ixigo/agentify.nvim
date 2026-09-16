local context = require("agentify.context")
local h = require("tests.helpers")

return {
  {
    name = "builds request context from current cursor state",
    fn = function()
      local opts = {
        suggestion = {
          max_context_lines = {
            before = 2,
            after = 2,
          },
        },
      }

      h.with_buffer({
        "local prefix = foo",
        "print(prefix)",
      }, function(bufnr)
        vim.bo[bufnr].filetype = "lua"
        local line = "local prefix = foo"
        vim.cmd("startinsert")
        vim.api.nvim_win_set_cursor(0, { 1, #line })

        local ctx = context.build(bufnr, opts)
        h.eq(line, ctx.line)
        h.eq(line:sub(1, ctx.col), ctx.line_prefix)
        h.eq(line, ctx.line_prefix .. ctx.line_suffix)
        h.eq({ "print(prefix)" }, ctx.after_lines)
        h.eq(#("localprefix=foo"), ctx.prefix_non_space_count)
      end)
    end,
  },
  {
    name = "sanitizes duplicated prefixes and suffix overlap",
    fn = function()
      local ctx = {
        line_prefix = "const result = foo",
        line_suffix = ");",
      }

      local text = context.sanitize_completion(ctx, "const result = foo(bar);")
      h.eq("(bar", text)
    end,
  },
  {
    name = "keeps multiline completion at end of line",
    fn = function()
      local ctx = {
        line_prefix = "if ready then",
        line_suffix = "",
      }
      local opts = {
        suggestion = {
          multiline = true,
          max_lines = 4,
        },
      }

      local text = context.sanitize_completion(ctx, "\n  return value\nend", opts)
      h.eq("\n  return value\nend", text)
    end,
  },
  {
    name = "falls back to single line when there is an active suffix",
    fn = function()
      local ctx = {
        line_prefix = "const value = ",
        line_suffix = " + other",
      }
      local opts = {
        suggestion = {
          multiline = true,
          max_lines = 4,
        },
      }

      local text = context.sanitize_completion(ctx, "compute(\n  foo,\n)", opts)
      h.eq("compute(", text)
    end,
  },
}
