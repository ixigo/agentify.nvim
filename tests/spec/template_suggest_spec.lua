local config = require("agentify.config")
local context = require("agentify.context")
local engine = require("agentify.engine")
local h = require("tests.helpers")
local state = require("agentify.state")
local template_suggest = require("agentify.template_suggest")

return {
  {
    name = "suggests an arrow-function block template for JS and TS",
    fn = function()
      h.with_buffer({ "const hello = () =>" }, function(bufnr)
        vim.bo[bufnr].filetype = "typescript"
        vim.bo[bufnr].expandtab = true
        vim.bo[bufnr].shiftwidth = 2
        vim.bo[bufnr].tabstop = 2
        vim.cmd("startinsert")
        vim.api.nvim_win_set_cursor(0, { 1, #"const hello = () =>" })

        local opts = config.normalize({})
        local ctx = context.build(bufnr, opts)
        local suggestion = template_suggest.suggest(ctx, opts)

        h.ok(suggestion)
        h.eq("template-arrow-function", suggestion.source)
        h.eq(" {\n  \n}", suggestion.text)
      end)
    end,
  },
  {
    name = "engine uses the arrow-function template before Codex",
    fn = function()
      h.with_buffer({ "const hello = () =>" }, function(bufnr)
        vim.bo[bufnr].filetype = "typescript"
        vim.bo[bufnr].expandtab = true
        vim.bo[bufnr].shiftwidth = 2
        vim.bo[bufnr].tabstop = 2
        vim.cmd("startinsert")
        vim.api.nvim_win_set_cursor(0, { 1, #"const hello = () =>" })

        local provider_calls = 0
        local fake_provider = {
          complete = function()
            provider_calls = provider_calls + 1
            return {
              cancel = function() end,
            }
          end,
          status = function(callback)
            callback({
              provider = "fake",
              transport = { running = false, initialized = false },
              thread = { warm = false },
              cli = { available = false, command = { "fake" } },
            })
          end,
          warmup = function(_, callback)
            if callback then
              callback(true, nil)
            end
          end,
        }

        local opts = config.normalize({})
        state.reset()
        engine.setup(opts, fake_provider)

        local ok, reason = engine.request(bufnr, { manual = false })
        h.eq(true, ok)
        h.eq("template-suggestion", reason)
        h.eq(0, provider_calls)
        h.eq(" {\n  \n}", state.get_buffer(bufnr).suggestion.text)
      end)
    end,
  },
  {
    name = "suggests console.log with the nearest declared identifier",
    fn = function()
      h.with_buffer({
        "const hello = createHello();",
        "console",
      }, function(bufnr)
        vim.bo[bufnr].filetype = "typescript"
        vim.bo[bufnr].expandtab = true
        vim.bo[bufnr].shiftwidth = 2
        vim.bo[bufnr].tabstop = 2
        vim.cmd("startinsert")
        vim.api.nvim_win_set_cursor(0, { 2, #"console" })

        local opts = config.normalize({})
        local ctx = context.build(bufnr, opts)
        local suggestion = template_suggest.suggest(ctx, opts)

        h.ok(suggestion)
        h.eq("template-console-log", suggestion.source)
        h.eq('.log("hello", hello);', suggestion.text)
      end)
    end,
  },
  {
    name = "engine uses the console.log template before Codex",
    fn = function()
      h.with_buffer({
        "const hello = createHello();",
        "console",
      }, function(bufnr)
        vim.bo[bufnr].filetype = "typescript"
        vim.bo[bufnr].expandtab = true
        vim.bo[bufnr].shiftwidth = 2
        vim.bo[bufnr].tabstop = 2
        vim.cmd("startinsert")
        vim.api.nvim_win_set_cursor(0, { 2, #"console" })

        local provider_calls = 0
        local fake_provider = {
          complete = function()
            provider_calls = provider_calls + 1
            return {
              cancel = function() end,
            }
          end,
          status = function(callback)
            callback({
              provider = "fake",
              transport = { running = false, initialized = false },
              thread = { warm = false },
              cli = { available = false, command = { "fake" } },
            })
          end,
          warmup = function(_, callback)
            if callback then
              callback(true, nil)
            end
          end,
        }

        local opts = config.normalize({})
        state.reset()
        engine.setup(opts, fake_provider)

        local ok, reason = engine.request(bufnr, { manual = false })
        h.eq(true, ok)
        h.eq("template-suggestion", reason)
        h.eq(0, provider_calls)
        h.eq('.log("hello", hello);', state.get_buffer(bufnr).suggestion.text)
      end)
    end,
  },
  {
    name = "suggests python print with the nearest declared identifier",
    fn = function()
      h.with_buffer({
        "hello = make_hello()",
        "print",
      }, function(bufnr)
        vim.bo[bufnr].filetype = "python"
        vim.bo[bufnr].expandtab = true
        vim.bo[bufnr].shiftwidth = 4
        vim.bo[bufnr].tabstop = 4
        vim.cmd("startinsert")
        vim.api.nvim_win_set_cursor(0, { 2, #"print" })

        local opts = config.normalize({})
        local ctx = context.build(bufnr, opts)
        local suggestion = template_suggest.suggest(ctx, opts)

        h.ok(suggestion)
        h.eq("template-print-debug", suggestion.source)
        h.eq("(\"hello\", hello)", suggestion.text)
      end)
    end,
  },
  {
    name = "engine uses the python print template before Codex",
    fn = function()
      h.with_buffer({
        "hello = make_hello()",
        "print",
      }, function(bufnr)
        vim.bo[bufnr].filetype = "python"
        vim.bo[bufnr].expandtab = true
        vim.bo[bufnr].shiftwidth = 4
        vim.bo[bufnr].tabstop = 4
        vim.cmd("startinsert")
        vim.api.nvim_win_set_cursor(0, { 2, #"print" })

        local provider_calls = 0
        local fake_provider = {
          complete = function()
            provider_calls = provider_calls + 1
            return {
              cancel = function() end,
            }
          end,
          status = function(callback)
            callback({
              provider = "fake",
              transport = { running = false, initialized = false },
              thread = { warm = false },
              cli = { available = false, command = { "fake" } },
            })
          end,
          warmup = function(_, callback)
            if callback then
              callback(true, nil)
            end
          end,
        }

        local opts = config.normalize({})
        state.reset()
        engine.setup(opts, fake_provider)

        local ok, reason = engine.request(bufnr, { manual = false })
        h.eq(true, ok)
        h.eq("template-suggestion", reason)
        h.eq(0, provider_calls)
        h.eq("(\"hello\", hello)", state.get_buffer(bufnr).suggestion.text)
      end)
    end,
  },
}
