local config = require("agentify.config")
local engine = require("agentify.engine")
local h = require("tests.helpers")
local state = require("agentify.state")

return {
  {
    name = "continues to Codex after a provisional function template",
    fn = function()
      h.with_buffer({
        "const convertArrayToString = (items) =>",
      }, function(bufnr)
        local original_get_mode = vim.api.nvim_get_mode
        vim.api.nvim_get_mode = function()
          return { mode = "i" }
        end

        local ok, result = xpcall(function()
          vim.bo[bufnr].filetype = "typescript"
          vim.bo[bufnr].expandtab = true
          vim.bo[bufnr].shiftwidth = 2
          vim.bo[bufnr].tabstop = 2
          vim.cmd("startinsert")
          vim.api.nvim_win_set_cursor(0, { 1, #"const convertArrayToString = (items) =>" })

          local provider_calls = 0
          local observed_context = nil
          local provider_callback = nil
          local fake_provider = {
            complete = function(_, ctx, callback)
              provider_calls = provider_calls + 1
              observed_context = ctx
              provider_callback = callback
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

          local ok = engine.request(bufnr, { manual = false })
          h.eq(true, ok)
          h.eq(1, provider_calls)
          h.ok(observed_context)
          h.eq("convertArrayToString", observed_context.intent.symbol_name)
          h.eq(true, observed_context.intent.prefer_provider)
          h.eq(" {\n  \n}", state.get_buffer(bufnr).suggestion.text)
          h.ok(state.get_buffer(bufnr).active_request)

          provider_callback({ type = "completed", text = "" })
          vim.wait(50, function()
            return state.get_buffer(bufnr).active_request == nil
          end)

          h.eq(" {\n  \n}", state.get_buffer(bufnr).suggestion.text)
        end, debug.traceback)

        vim.api.nvim_get_mode = original_get_mode
        if not ok then
          error(result, 0)
        end
      end)
    end,
  },
}
