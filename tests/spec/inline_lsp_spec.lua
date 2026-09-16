local h = require("tests.helpers")
local inline_lsp = require("agentify.inline_lsp")

local function wait_for(predicate)
  return vim.wait(2000, predicate, 10)
end

local function make_deps(text, opts)
  opts = opts or {}
  local deps = { calls = {}, cancelled = {} }

  function deps.compute(bufnr, request_opts, callback)
    table.insert(deps.calls, { bufnr = bufnr, manual = request_opts.manual })
    local handle = {}
    function handle.cancel(reason)
      table.insert(deps.cancelled, reason)
    end
    if not opts.hang then
      vim.schedule(function()
        callback(text, "test")
      end)
    end
    return handle
  end

  return deps
end

return {
  {
    name = "answers initialize with inline completion capability",
    fn = function()
      local server = inline_lsp.make_server(make_deps("x"))({})
      local result
      server.request("initialize", {}, function(_, response)
        result = response
      end)

      h.ok(wait_for(function()
        return result ~= nil
      end))
      h.eq(true, result.capabilities.inlineCompletionProvider)
      h.eq("agentify", result.serverInfo.name)
      h.eq(false, server.is_closing())
    end,
  },
  {
    name = "returns computed text as an inline completion item",
    fn = function()
      h.with_buffer({ "local value = " }, function(bufnr)
        vim.api.nvim_buf_set_name(bufnr, "/tmp/agentify_inline_a.lua")
        local deps = make_deps("42")
        local server = inline_lsp.make_server(deps)({})
        local result
        server.request("textDocument/inlineCompletion", {
          textDocument = { uri = vim.uri_from_bufnr(bufnr) },
          position = { line = 0, character = 14 },
          context = { triggerKind = 2 },
        }, function(_, response)
          result = response
        end)

        h.ok(wait_for(function()
          return result ~= nil
        end))
        local position = { line = 0, character = 14 }
        h.eq({ items = { { insertText = "42", range = { start = position, ["end"] = position } } } }, result)
        h.eq(bufnr, deps.calls[1].bufnr)
        h.eq(false, deps.calls[1].manual)
      end)
    end,
  },
  {
    name = "returns an empty list when nothing was computed and honours manual flags",
    fn = function()
      h.with_buffer({ "" }, function(bufnr)
        vim.api.nvim_buf_set_name(bufnr, "/tmp/agentify_inline_b.lua")
        local deps = make_deps(nil)
        local server = inline_lsp.make_server(deps)({})
        inline_lsp.manual_next[bufnr] = true

        local result
        server.request("textDocument/inlineCompletion", {
          textDocument = { uri = vim.uri_from_bufnr(bufnr) },
          context = { triggerKind = 2 },
        }, function(_, response)
          result = response
        end)

        h.ok(wait_for(function()
          return result ~= nil
        end))
        h.eq({ items = {} }, result)
        h.eq(true, deps.calls[1].manual)
        h.eq(nil, inline_lsp.manual_next[bufnr])
      end)
    end,
  },
  {
    name = "cancels superseded and explicitly cancelled requests",
    fn = function()
      h.with_buffer({ "" }, function(bufnr)
        vim.api.nvim_buf_set_name(bufnr, "/tmp/agentify_inline_c.lua")
        local deps = make_deps("never", { hang = true })
        local server = inline_lsp.make_server(deps)({})
        local params = {
          textDocument = { uri = vim.uri_from_bufnr(bufnr) },
          context = { triggerKind = 2 },
        }

        local ids = {}
        server.request("textDocument/inlineCompletion", params, function() end, function(id)
          ids[#ids + 1] = id
        end)
        server.request("textDocument/inlineCompletion", params, function() end, function(id)
          ids[#ids + 1] = id
        end)
        h.eq({ "superseded" }, deps.cancelled)

        server.notify("$/cancelRequest", { id = ids[2] })
        h.eq({ "superseded", "lsp-cancelled" }, deps.cancelled)

        server.terminate()
        h.eq(true, server.is_closing())
      end)
    end,
  },
  {
    name = "reports support based on the running Neovim",
    fn = function()
      h.eq(vim.lsp.inline_completion ~= nil, inline_lsp.is_supported())
    end,
  },
}
