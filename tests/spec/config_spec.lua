local config = require("agentify.config")
local h = require("tests.helpers")

return {
  {
    name = "normalizes custom filetype config",
    fn = function()
      local opts = config.normalize({
        debounce_ms = 120,
        filetypes = {
          allow = { "lua" },
          deny = { "markdown" },
        },
      })

      h.eq(120, opts.debounce_ms)
      h.eq({ "lua" }, opts.filetypes.allow)
      h.eq({ "markdown" }, opts.filetypes.deny)
      h.eq(true, opts.lsp.enabled)
      h.eq(2, opts.lsp.min_chars)
      h.eq(true, opts.intent.enabled)
      h.eq(4, opts.intent.max_open_buffers)
    end,
  },
  {
    name = "rejects invalid debounce",
    fn = function()
      local ok, err = pcall(config.normalize, {
        debounce_ms = 0,
      })

      h.eq(false, ok)
      h.match("debounce_ms", err)
    end,
  },
  {
    name = "checks filetype allowlist",
    fn = function()
      local opts = config.normalize({
        filetypes = {
          allow = { "lua" },
          deny = {},
        },
      })

      h.with_buffer({ "local value = 1" }, function(bufnr)
        vim.bo[bufnr].filetype = "lua"
        local enabled = config.is_buffer_enabled(opts, bufnr)
        h.eq(true, enabled)
      end)
    end,
  },
}
