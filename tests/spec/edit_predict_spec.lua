local config = require("agentify.config")
local edit_predict = require("agentify.edit_predict")
local edits = require("agentify.edits")
local engine = require("agentify.engine")
local h = require("tests.helpers")
local prompt = require("agentify.provider.prompt")
local state = require("agentify.state")

local function fake_provider(reply)
  local provider = { calls = 0, last_ctx = nil }
  function provider.complete(_, ctx, callback)
    provider.calls = provider.calls + 1
    provider.last_ctx = ctx
    vim.schedule(function()
      callback({ type = "completed", text = type(reply) == "function" and reply(ctx) or reply })
    end)
    return { cancel = function() end }
  end
  function provider.status(_, cb)
    cb({ provider = "fake", cli = { available = false, command = {} }, transport = {}, thread = {} })
  end
  function provider.warmup(_, cb)
    if cb then
      cb(true)
    end
  end
  return provider
end

local function with_engine(lines, reply, fn, overrides)
  local original_get_mode = vim.api.nvim_get_mode
  vim.api.nvim_get_mode = function()
    return { mode = "n", blocking = false }
  end

  local provider = fake_provider(reply)
  state.reset()
  edits.reset()
  edit_predict.reset()
  engine.setup(config.normalize(vim.tbl_deep_extend("force", { budget = { notify = false } }, overrides or {})), provider)

  local ok, err = pcall(h.with_buffer, lines, function(bufnr)
    vim.bo[bufnr].filetype = "lua"
    edits.attach(bufnr, engine.opts.edits)
    return fn(bufnr, provider)
  end)

  vim.api.nvim_get_mode = original_get_mode
  if not ok then
    error(err, 0)
  end
end

return {
  {
    name = "records and coalesces edits from buffer updates",
    fn = function()
      edits.reset()
      h.with_buffer({ "local count = 1", "print(count)", "return count" }, function(bufnr)
        h.eq(true, edits.attach(bufnr, { max_edits = 8, coalesce_s = 5 }))

        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "local total = 1" })
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "local total_count = 1" })
        local recent = edits.recent(bufnr)
        h.eq(1, #recent, "consecutive edits on one row coalesce")
        h.eq("local count = 1", recent[1].old)
        h.eq("local total_count = 1", recent[1].new)

        vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { "return total_count" })
        recent = edits.recent(bufnr)
        h.eq(2, #recent)
        h.eq(2, recent[2].row)

        h.eq({ "L1: local count = 1  ->  local total_count = 1", "L3: return count  ->  return total_count" }, edits.describe(bufnr, 5))

        -- suppressed changes (our own accepts) are not recorded but keep the shadow in sync
        edits.suppress_next(bufnr, 1)
        vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "print(total_count)" })
        h.eq(2, #edits.recent(bufnr))
        vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "print(total_count) -- x" })
        h.eq("print(total_count)", edits.recent(bufnr)[3].old)
      end)
    end,
  },
  {
    name = "parses and validates a prediction against the window",
    fn = function()
      local ctx = {
        row = 0,
        window = { start_row = 0, lines = { "local total = 1", "print(count)", "return count" } },
      }
      local prediction = edit_predict.parse('Sure: {"line": 2, "old": "count", "new": "total"}', ctx)
      h.eq(1, prediction.row)
      h.eq(6, prediction.col)
      h.eq(11, prediction.end_col)
      h.eq("print(count)", prediction.line)

      h.eq(nil, edit_predict.parse("{}", ctx))
      h.eq(nil, edit_predict.parse('{"line": 1, "old": "total", "new": "x"}', ctx), "cursor line is excluded")
      h.eq(nil, edit_predict.parse('{"line": 3, "old": "missing", "new": "x"}', ctx))
      h.eq(nil, edit_predict.parse('{"line": 3, "old": "count", "new": "count"}', ctx))
      h.eq(nil, edit_predict.parse('{"line": 9, "old": "count", "new": "x"}', ctx))
      h.eq(nil, edit_predict.parse("not json", ctx))
    end,
  },
  {
    name = "renders strikethrough plus ghost text and applies on accept",
    fn = function()
      edit_predict.reset()
      h.with_buffer({ "local total = 1", "print(count)", "return count" }, function(bufnr)
        local opts = config.normalize({}).edit_prediction
        local prediction = edit_predict.parse('{"line": 2, "old": "count", "new": "total"}', {
          row = 0,
          window = { start_row = 0, lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) },
        })
        h.eq(true, edit_predict.show(bufnr, prediction, opts))
        h.eq(true, edit_predict.has(bufnr))

        local marks = vim.api.nvim_buf_get_extmarks(bufnr, edit_predict.namespace, 0, -1, { details = true })
        h.eq(2, #marks)
        h.eq("AgentifyEditOld", marks[1][4].hl_group)
        h.eq(11, marks[1][4].end_col)
        h.eq("total", marks[2][4].virt_text[1][1])
        h.eq("AgentifyEditNew", marks[2][4].virt_text[1][2])

        h.eq(true, edit_predict.accept(bufnr))
        h.eq("print(total)", vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1])
        h.eq(false, edit_predict.has(bufnr))
        h.eq(0, #vim.api.nvim_buf_get_extmarks(bufnr, edit_predict.namespace, 0, -1, {}))

        -- a stale prediction (line changed underneath) is refused
        edit_predict.show(bufnr, prediction, opts)
        h.eq(false, edit_predict.has(bufnr), "show must refuse when the line no longer matches")
      end)
    end,
  },
  {
    name = "builds an edit request and keeps completion requests unchanged",
    fn = function()
      local opts = config.normalize({})
      local ctx = {
        mode = "edit",
        filepath = "/repo/a.lua",
        filetype = "lua",
        row = 4,
        recent_edits = { "L1: local count = 1  ->  local total = 1" },
        window = { start_row = 3, lines = { "print(count)", "return count" } },
      }
      local request = prompt.build_completion_request(ctx, opts)
      h.match("EDIT PREDICTION request", request)
      h.match("CURSOR_LINE: 5", request)
      h.match("RECENT_EDITS:\nL1: local count = 1  %->  local total = 1", request)
      h.match("BUFFER_WINDOW:\n4: print%(count%)\n5: return count", request)
      h.match('{"line": <line number from the window>, "old"', request)

      local completion_ctx = {
        filepath = "", filetype = "lua", expandtab = true, tabstop = 2, shiftwidth = 2,
        before_lines = {}, line_prefix = "x", line_suffix = "", after_lines = {},
        recent_edits = { "L1: a  ->  b" },
      }
      local completion = prompt.build_completion_request(completion_ctx, opts)
      h.ok(not completion:find("EDIT PREDICTION", 1, true))
      h.match("RECENT_EDITS:\nL1: a  %->  b", completion)
    end,
  },
  {
    name = "engine predicts after an edit and accept() applies it when no ghost text is showing",
    fn = function()
      with_engine({ "local count = 1", "print(count)", "return count" }, function(ctx)
        h.eq("edit", ctx.mode)
        return '{"line": 2, "old": "count", "new": "total"}'
      end, function(bufnr, provider)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        -- nothing to predict from yet
        local ok, reason = engine.predict_edit(bufnr)
        h.eq(false, ok)
        h.match("no recent edits", reason)

        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "local total = 1" })
        h.eq(1, #edits.recent(bufnr))

        h.eq(true, (engine.predict_edit(bufnr)))
        h.ok(vim.wait(2000, function()
          return engine.has_edit_prediction(bufnr)
        end, 10), "expected a rendered prediction")
        h.eq(1, provider.calls)
        h.match("RECENT_EDITS", prompt.build_completion_request(provider.last_ctx, engine.opts))

        h.eq(true, engine.accept(bufnr))
        h.eq("print(total)", vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1])
        h.eq(false, engine.has_edit_prediction(bufnr))
        -- our own change is not remembered as a user edit
        h.eq(1, #edits.recent(bufnr))
        h.eq(1, engine.budget.stats.edit_prediction)
        h.eq(1, engine.budget.stats.edit_accepted)
      end)
    end,
  },
  {
    name = "an unusable reply shows nothing, and dismiss clears a prediction",
    fn = function()
      with_engine({ "local count = 1", "print(count)" }, "{}", function(bufnr, provider)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "local total = 1" })
        h.eq(true, (engine.predict_edit(bufnr)))
        vim.wait(300, function()
          return false
        end, 20)
        h.eq(1, provider.calls)
        h.eq(false, engine.has_edit_prediction(bufnr))

        local opts = config.normalize({}).edit_prediction
        require("agentify.edit_predict").show(bufnr, {
          row = 1, col = 6, end_col = 11, old = "count", new = "total", line = "print(count)",
        }, opts)
        h.eq(true, engine.has_edit_prediction(bufnr))
        h.eq(true, engine.dismiss(bufnr))
        h.eq(false, engine.has_edit_prediction(bufnr))
      end)
    end,
  },
  {
    name = "prediction is skipped while a suggestion is visible or when disabled",
    fn = function()
      with_engine({ "local count = 1", "print(count)" }, "{}", function(bufnr, provider)
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "local total = 1" })
        engine.show_suggestion(bufnr, { row = 0, col = 15, text = ";", source = "test" })
        local ok, reason = engine.predict_edit(bufnr)
        h.eq(false, ok)
        h.match("suggestion visible", reason)
        h.eq(0, provider.calls)
      end)

      with_engine({ "local count = 1" }, "{}", function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "local total = 1" })
        local ok, reason = engine.predict_edit(bufnr)
        h.eq(false, ok)
        h.eq("disabled", reason)
      end, { edit_prediction = { enabled = false } })
    end,
  },
}
