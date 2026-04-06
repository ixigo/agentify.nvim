local config = require("agentify.config")
local context = require("agentify.context")
local engine = require("agentify.engine")
local h = require("tests.helpers")
local lsp = require("agentify.lsp")
local state = require("agentify.state")

local function with_mocked_lsp(mock, callback)
  local original = {
    get_clients = vim.lsp.get_clients,
    buf_request_sync = vim.lsp.buf_request_sync,
    make_position_params = vim.lsp.util.make_position_params,
    diagnostic_get = vim.diagnostic.get,
  }

  vim.lsp.get_clients = mock.get_clients or original.get_clients
  vim.lsp.buf_request_sync = mock.buf_request_sync or original.buf_request_sync
  vim.lsp.util.make_position_params = mock.make_position_params or original.make_position_params
  vim.diagnostic.get = mock.diagnostic_get or original.diagnostic_get

  local ok, result = xpcall(function()
    return callback()
  end, debug.traceback)

  vim.lsp.get_clients = original.get_clients
  vim.lsp.buf_request_sync = original.buf_request_sync
  vim.lsp.util.make_position_params = original.make_position_params
  vim.diagnostic.get = original.diagnostic_get

  if not ok then
    error(result, 0)
  end

  return result
end

local function mock_client()
  return {
    name = "tsserver",
    supports_method = function(_, method)
      return method == "textDocument/completion"
    end,
  }
end

return {
  {
    name = "collects LSP completion suggestions and diagnostics",
    fn = function()
      with_mocked_lsp({
        get_clients = function()
          return { mock_client() }
        end,
        diagnostic_get = function()
          return {
            { severity = vim.diagnostic.severity.WARN, message = "Prefer greetUser over greetLegacy" },
          }
        end,
        make_position_params = function()
          return {
            textDocument = { uri = "file:///test.ts" },
            position = { line = 0, character = 17 },
          }
        end,
        buf_request_sync = function()
          return {
            [1] = {
              result = {
                items = {
                  {
                    label = "greetUser",
                    insertText = "greetUser($1)",
                    insertTextFormat = 2,
                    kind = 3,
                  },
                  {
                    label = "greetLegacy",
                    insertText = "greetLegacy",
                    kind = 3,
                  },
                },
              },
            },
          }
        end,
      }, function()
        h.with_buffer({ "const value = gre" }, function(bufnr)
          vim.bo[bufnr].filetype = "typescript"
          vim.cmd("startinsert")
          vim.api.nvim_win_set_cursor(0, { 1, #"const value = gre" })

          local opts = config.normalize({})
          local ctx = context.build(bufnr, opts)
          ctx.lsp = lsp.snapshot(bufnr, ctx.row, opts)

          local suggestion = lsp.suggest(bufnr, ctx, opts, function(text)
            return context.sanitize_completion(ctx, text, opts)
          end)

          h.ok(suggestion)
          h.eq("lsp-completion", suggestion.source)
          h.eq("etUser()", suggestion.text)
          h.eq({ "tsserver" }, ctx.lsp.clients)
          h.eq({ "Warn: Prefer greetUser over greetLegacy" }, ctx.lsp.diagnostics)
          h.eq({
            "greetUser (kind 3)",
            "greetLegacy (kind 3)",
          }, ctx.lsp.completions)
        end)
      end)
    end,
  },
  {
    name = "engine uses LSP completion before Codex",
    fn = function()
      with_mocked_lsp({
        get_clients = function()
          return { mock_client() }
        end,
        diagnostic_get = function()
          return {}
        end,
        make_position_params = function()
          return {
            textDocument = { uri = "file:///test.ts" },
            position = { line = 0, character = 17 },
          }
        end,
        buf_request_sync = function()
          return {
            [1] = {
              result = {
                items = {
                  {
                    label = "greetUser",
                    insertText = "greetUser($1)",
                    insertTextFormat = 2,
                    kind = 3,
                  },
                },
              },
            },
          }
        end,
      }, function()
        h.with_buffer({ "const value = gre" }, function(bufnr)
          vim.bo[bufnr].filetype = "typescript"
          vim.cmd("startinsert")
          vim.api.nvim_win_set_cursor(0, { 1, #"const value = gre" })

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
          h.eq("lsp-suggestion", reason)
          h.eq(0, provider_calls)
          h.eq("etUser()", state.get_buffer(bufnr).suggestion.text)
        end)
      end)
    end,
  },
  {
    name = "engine uses LSP completion in a python buffer",
    fn = function()
      with_mocked_lsp({
        get_clients = function()
          return {
            {
              name = "pyright",
              supports_method = function(_, method)
                return method == "textDocument/completion"
              end,
            },
          }
        end,
        diagnostic_get = function()
          return {}
        end,
        make_position_params = function()
          return {
            textDocument = { uri = "file:///test.py" },
            position = { line = 0, character = 11 },
          }
        end,
        buf_request_sync = function()
          return {
            [1] = {
              result = {
                items = {
                  {
                    label = "request_data",
                    insertText = "request_data",
                    kind = 6,
                  },
                },
              },
            },
          }
        end,
      }, function()
        h.with_buffer({ "value = req" }, function(bufnr)
          vim.bo[bufnr].filetype = "python"
          vim.cmd("startinsert")
          vim.api.nvim_win_set_cursor(0, { 1, #"value = req" })

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
          h.eq("lsp-suggestion", reason)
          h.eq(0, provider_calls)
          h.eq("uest_data", state.get_buffer(bufnr).suggestion.text)
        end)
      end)
    end,
  },
}
