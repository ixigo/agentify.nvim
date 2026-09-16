local actions = require("agentify.actions")
local config = require("agentify.config")
local engine = require("agentify.engine")
local h = require("tests.helpers")
local recall = require("agentify.recall")
local state = require("agentify.state")

local function fake_provider()
  local provider = { calls = 0 }
  function provider.complete(_, _, _)
    provider.calls = provider.calls + 1
    return { cancel = function() end }
  end
  function provider.status(_, callback)
    callback({ provider = "fake", cli = { available = false, command = { "fake" } }, transport = {}, thread = {} })
  end
  function provider.warmup(_, callback)
    if callback then
      callback(true, nil)
    end
  end
  return provider
end

-- Runs `fn` with the engine set up, insert mode mocked, and a lua buffer holding `lines`.
local function with_engine(lines, fn, overrides)
  local original_get_mode = vim.api.nvim_get_mode
  vim.api.nvim_get_mode = function()
    return { mode = "i", blocking = false }
  end

  local provider = fake_provider()
  state.reset()
  recall.clear()
  engine.setup(config.normalize(overrides or {}), provider)

  local ok, err = pcall(h.with_buffer, lines, function(bufnr)
    vim.bo[bufnr].filetype = "lua"
    vim.cmd("startinsert")
    return fn(bufnr, provider)
  end)

  vim.api.nvim_get_mode = original_get_mode
  if not ok then
    error(err, 0)
  end
end

local function set_line(bufnr, text, col)
  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { text })
  vim.api.nvim_win_set_cursor(0, { 1, col or #text })
end

local function show(bufnr, col, text)
  return engine.show_suggestion(bufnr, { row = 0, col = col, text = text, source = "test" })
end

return {
  {
    name = "type-through shortens the ghost text as matching characters are typed",
    fn = function()
      with_engine({ "local value = " }, function(bufnr)
        show(bufnr, 14, "compute(x)")

        set_line(bufnr, "local value = c")
        h.eq("shortened", engine.reconcile(bufnr))
        h.eq("ompute(x)", state.get_buffer(bufnr).suggestion.text)
        h.eq(15, state.get_buffer(bufnr).suggestion.col)

        set_line(bufnr, "local value = com")
        h.eq("shortened", engine.reconcile(bufnr))
        h.eq("pute(x)", state.get_buffer(bufnr).suggestion.text)

        h.eq("kept", engine.reconcile(bufnr))
      end)
    end,
  },
  {
    name = "type-through gives up on a mismatch or when the suffix changes",
    fn = function()
      with_engine({ "local value = " }, function(bufnr)
        show(bufnr, 14, "compute(x)")
        set_line(bufnr, "local value = x")
        h.eq(nil, engine.reconcile(bufnr))

        show(bufnr, 14, "compute(x)")
        set_line(bufnr, "local value = c;", 15)
        h.eq(nil, engine.reconcile(bufnr))
      end)
    end,
  },
  {
    name = "typing the whole suggestion dismisses it",
    fn = function()
      with_engine({ "return " }, function(bufnr)
        show(bufnr, 7, "value")
        set_line(bufnr, "return value")
        h.eq(nil, engine.reconcile(bufnr))
        h.eq(nil, state.get_buffer(bufnr).suggestion)
      end)
    end,
  },
  {
    name = "type-through can be disabled",
    fn = function()
      with_engine({ "return " }, function(bufnr)
        show(bufnr, 7, "value")
        set_line(bufnr, "return v")
        h.eq(nil, engine.reconcile(bufnr))
      end, { type_through = false })
    end,
  },
  {
    name = "recall re-shows a remembered suggestion after backspacing",
    fn = function()
      with_engine({ "local value = " }, function(bufnr)
        show(bufnr, 14, "compute(x)")
        set_line(bufnr, "local value = c")
        engine.reconcile(bufnr)
        set_line(bufnr, "local value = co")
        engine.reconcile(bufnr)
        h.eq(3, recall.count(bufnr))

        -- deviate, then come back
        set_line(bufnr, "local value = cox")
        h.eq(nil, engine.reconcile(bufnr))
        actions.dismiss(bufnr)

        set_line(bufnr, "local value = co")
        h.eq(true, engine.recall_show(bufnr))
        h.eq("mpute(x)", state.get_buffer(bufnr).suggestion.text)
        h.eq("recall", state.get_buffer(bufnr).suggestion.source)

        set_line(bufnr, "local value = zz")
        h.eq(false, engine.recall_show(bufnr))
      end)
    end,
  },
  {
    name = "an explicit dismiss forgets the recall entry for that context",
    fn = function()
      with_engine({ "local value = " }, function(bufnr)
        show(bufnr, 14, "compute(x)")
        h.eq(1, recall.count(bufnr))
        engine.dismiss(bufnr)
        h.eq(0, recall.count(bufnr))
        h.eq(false, engine.recall_show(bufnr))
      end)
    end,
  },
  {
    name = "accept_word inserts a word and keeps the remainder visible",
    fn = function()
      with_engine({ "return " }, function(bufnr)
        show(bufnr, 7, "value + rest")
        h.eq(true, engine.accept_word(bufnr))
        h.eq("return value ", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])

        local suggestion = state.get_buffer(bufnr).suggestion
        h.eq("+ rest", suggestion.text)
        h.eq(13, suggestion.col)
        h.eq("test", suggestion.source)
      end)
    end,
  },
  {
    name = "accept_line inserts the first line and keeps following lines",
    fn = function()
      with_engine({ "if ready then " }, function(bufnr)
        show(bufnr, 14, "return value\nend")
        h.eq(true, engine.accept_line(bufnr))
        h.eq("if ready then return value", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])

        local suggestion = state.get_buffer(bufnr).suggestion
        h.eq("\nend", suggestion.text)
        h.eq(26, suggestion.col)

        -- accepting the final fragment leaves nothing behind
        h.eq(true, engine.accept_line(bufnr))
        h.eq({ "if ready then return value", "end" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
        h.eq(nil, state.get_buffer(bufnr).suggestion)
      end)
    end,
  },
  {
    name = "first_line_fragment handles suggestions that start with a line break",
    fn = function()
      h.eq("return x", actions.first_line_fragment("return x\nend"))
      h.eq("\n  return x", actions.first_line_fragment("\n  return x\nend"))
      h.eq("single", actions.first_line_fragment("single"))
    end,
  },
  {
    name = "a full accept prefetches the next suggestion",
    fn = function()
      with_engine({ "local total = " }, function(bufnr)
        local requests = 0
        local original_request = engine.request
        engine.request = function(...)
          requests = requests + 1
          return original_request(...)
        end

        show(bufnr, 14, "sum(items)")
        h.eq(true, engine.accept(bufnr))
        h.eq("local total = sum(items)", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
        h.ok(vim.wait(500, function()
          return requests == 1
        end, 10), "expected a prefetch request after accept")

        engine.request = original_request
      end)
    end,
  },
  {
    name = "prefetch can be disabled",
    fn = function()
      with_engine({ "local total = " }, function(bufnr)
        local requests = 0
        local original_request = engine.request
        engine.request = function(...)
          requests = requests + 1
          return original_request(...)
        end

        show(bufnr, 14, "sum(items)")
        engine.accept(bufnr)
        vim.wait(100, function()
          return false
        end, 10)
        h.eq(0, requests)

        engine.request = original_request
      end, { prefetch_after_accept = false })
    end,
  },
  {
    name = "debounce grows while a provider request is in flight",
    fn = function()
      with_engine({ "x" }, function(bufnr)
        h.eq(175, engine.debounce_delay(bufnr))
        state.get_buffer(bufnr).active_request = { token = 1, handle = { cancel = function() end } }
        h.eq(320, engine.debounce_delay(bufnr))
        state.get_buffer(bufnr).active_request = nil
      end)
    end,
  },
  {
    name = "recall keeps the newest entries within max_entries",
    fn = function()
      recall.clear(99)
      for index = 1, 5 do
        recall.remember(99, recall.key(0, "p" .. index, ""), "t" .. index, 3)
      end
      h.eq(3, recall.count(99))
      h.eq(nil, recall.lookup(99, recall.key(0, "p1", "")))
      h.eq("t5", recall.lookup(99, recall.key(0, "p5", "")))
      recall.forget(99, recall.key(0, "p5", ""))
      h.eq(2, recall.count(99))
      recall.clear(99)
    end,
  },
}
