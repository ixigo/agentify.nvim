local config = require("agentify.config")
local engine = require("agentify.engine")
local h = require("tests.helpers")
local jump = require("agentify.jump")
local state = require("agentify.state")

local function jump_opts(overrides)
  return config.normalize({ jump = overrides or {} }).jump
end

local function with_diagnostics(list, fn)
  local original = vim.diagnostic.get
  vim.diagnostic.get = function()
    return list
  end
  local ok, err = pcall(fn)
  vim.diagnostic.get = original
  if not ok then
    error(err, 0)
  end
end

return {
  {
    name = "prefers the nearest diagnostic below the cursor within max_distance",
    fn = function()
      h.with_buffer({ "a", "b", "c", "d", "e" }, function(bufnr)
        with_diagnostics({
          { lnum = 4, col = 1, severity = vim.diagnostic.severity.ERROR, message = "far error" },
          { lnum = 2, col = 3, severity = vim.diagnostic.severity.WARN, message = "near warning\nsecond line" },
          { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "above cursor" },
          { lnum = 3, col = 0, severity = vim.diagnostic.severity.HINT, message = "hint ignored" },
        }, function()
          local target = jump.find_target(bufnr, 0, jump_opts())
          h.eq(2, target.row)
          h.eq(3, target.col)
          h.eq("diagnostic", target.kind)
          h.eq("warning: near warning", target.reason)

          h.eq(nil, jump.find_target(bufnr, 0, jump_opts({ max_distance = 1 })))
          h.eq(4, jump.find_target(bufnr, 2, jump_opts()).row)
          h.eq(nil, jump.find_target(bufnr, 1, jump_opts({ diagnostics = false, placeholders = false })))
        end)
      end)
    end,
  },
  {
    name = "falls back to placeholders and points inside empty blocks",
    fn = function()
      h.with_buffer({
        "function a() {",
        "  return 1;",
        "}",
        "function b() {}",
        "// TODO handle errors",
        "def c():",
        "    pass",
      }, function(bufnr)
        with_diagnostics({}, function()
          local opts = jump_opts()
          local target = jump.find_target(bufnr, 0, opts)
          h.eq(3, target.row)
          h.eq("empty block", target.reason)
          h.eq(14, target.col)

          target = jump.find_target(bufnr, 3, opts)
          h.eq(4, target.row)
          h.eq("TODO", target.reason)

          target = jump.find_target(bufnr, 5, opts)
          h.eq(6, target.row)
          h.eq("empty body", target.reason)

          h.eq(nil, jump.find_target(bufnr, 6, opts))
        end)
      end)
    end,
  },
  {
    name = "shows a hint, jumps to it, and clears afterwards",
    fn = function()
      h.with_buffer({ "const x = 1;", "function b() {}", "" }, function(bufnr)
        with_diagnostics({}, function()
          vim.api.nvim_win_set_cursor(0, { 1, 0 })
          local target = jump.suggest(bufnr, jump_opts())
          h.eq(1, target.row)
          h.eq(true, jump.has(bufnr))
          h.eq(1, #vim.api.nvim_buf_get_extmarks(bufnr, jump.namespace, 0, -1, {}))

          h.eq(true, jump.jump(bufnr))
          local cursor = vim.api.nvim_win_get_cursor(0)
          h.eq({ 2, 14 }, cursor)
          h.eq(false, jump.has(bufnr))
          h.eq(0, #vim.api.nvim_buf_get_extmarks(bufnr, jump.namespace, 0, -1, {}))
          h.eq(false, jump.jump(bufnr))
        end)
      end)
    end,
  },
  {
    name = "the hint survives on its origin and target lines and clears elsewhere",
    fn = function()
      h.with_buffer({ "one", "two", "// TODO", "four" }, function(bufnr)
        with_diagnostics({}, function()
          vim.api.nvim_win_set_cursor(0, { 1, 0 })
          jump.suggest(bufnr, jump_opts())
          h.eq(true, jump.has(bufnr))

          vim.api.nvim_win_set_cursor(0, { 1, 2 })
          jump.on_cursor_moved(bufnr)
          h.eq(true, jump.has(bufnr))

          vim.api.nvim_win_set_cursor(0, { 3, 0 })
          jump.on_cursor_moved(bufnr)
          h.eq(true, jump.has(bufnr))

          vim.api.nvim_win_set_cursor(0, { 4, 0 })
          jump.on_cursor_moved(bufnr)
          h.eq(false, jump.has(bufnr))
        end)
      end)
    end,
  },
  {
    name = "a full accept produces a next-edit hint",
    fn = function()
      local original_get_mode = vim.api.nvim_get_mode
      vim.api.nvim_get_mode = function()
        return { mode = "i", blocking = false }
      end

      local provider = {
        complete = function()
          return { cancel = function() end }
        end,
        status = function(_, cb)
          cb({ provider = "fake", cli = { available = false, command = {} }, transport = {}, thread = {} })
        end,
        warmup = function(_, cb)
          if cb then
            cb(true)
          end
        end,
      }
      state.reset()
      jump.reset()
      engine.setup(config.normalize({ budget = { notify = false }, prefetch_after_accept = false }), provider)

      local ok, err = pcall(h.with_buffer, { "const total = ", "function later() {}" }, function(bufnr)
        vim.bo[bufnr].filetype = "javascript"
        vim.cmd("startinsert")
        with_diagnostics({}, function()
          engine.show_suggestion(bufnr, { row = 0, col = 14, text = "sum(items);", source = "test" })
          h.eq(true, engine.accept(bufnr))
          h.ok(vim.wait(500, function()
            return engine.has_jump_hint(bufnr)
          end, 10), "expected a jump hint after accept")
          h.eq(1, jump.get(bufnr).row)
          h.eq(true, engine.jump(bufnr))
          h.eq(2, vim.api.nvim_win_get_cursor(0)[1])
        end)
      end)

      vim.api.nvim_get_mode = original_get_mode
      if not ok then
        error(err, 0)
      end
    end,
  },
  {
    name = "jump hints can be disabled",
    fn = function()
      h.with_buffer({ "x", "// TODO" }, function(bufnr)
        with_diagnostics({}, function()
          vim.api.nvim_win_set_cursor(0, { 1, 0 })
          h.eq(nil, jump.suggest(bufnr, jump_opts({ enabled = false })))
          h.eq(false, jump.has(bufnr))
        end)
      end)
    end,
  },
}
