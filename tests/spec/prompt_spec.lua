local config = require("agentify.config")
local context = require("agentify.context")
local h = require("tests.helpers")
local intent = require("agentify.intent")
local prompt = require("agentify.provider.prompt")

return {
  {
    name = "builds a Codex prompt with intent and related buffer context",
    fn = function()
      local peer = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(peer, 0, -1, false, {
        "export function joinArray(array: string[]) {",
        '  const stringValue = array.join(", ");',
        "  return stringValue;",
        "}",
      })
      vim.bo[peer].filetype = "typescript"

      local ok, result = xpcall(function()
        h.with_buffer({
          "const convertArrayToString = (items) =>",
        }, function(bufnr)
          vim.bo[bufnr].filetype = "typescript"
          vim.bo[bufnr].expandtab = true
          vim.bo[bufnr].shiftwidth = 2
          vim.bo[bufnr].tabstop = 2
          vim.cmd("startinsert")
          vim.api.nvim_win_set_cursor(0, { 1, #"const convertArrayToString = (items) =>" })

          local opts = config.normalize({})
          local ctx = context.build(bufnr, opts)
          ctx.intent = intent.analyze(bufnr, ctx, opts)

          local request = prompt.build_completion_request(ctx, opts)
          h.match("INTENT_SYMBOL:\nconvertArrayToString", request)
          h.match("INTENT_PARAMETERS:\nitems", request)
          h.match("INTENT_HINTS:\n", request)
          h.match("RELATED_BUFFER_LINES:\n", request)
          h.match("joinArray", request)
        end)
      end, debug.traceback)

      if vim.api.nvim_buf_is_valid(peer) then
        vim.api.nvim_buf_delete(peer, { force = true })
      end

      if not ok then
        error(result, 0)
      end
    end,
  },
  {
    name = "shares base instructions across providers with per-provider overrides",
    fn = function()
      local opts = config.normalize({
        providers = {
          claude = { base_instructions = "Prefer snake_case." },
        },
      })

      local claude_text = prompt.base_instructions(opts, opts.providers.claude)
      h.match("independent completion request", claude_text)
      h.match("Prefer snake_case%.", claude_text)
      h.match("Return at most 4 lines%.", claude_text)

      local codex_text = prompt.base_instructions(opts, opts.providers.codex)
      h.ok(not codex_text:find("snake_case", 1, true), "codex must not inherit the claude override")

      local legacy = require("agentify.provider.codex_prompt")
      h.eq(codex_text, legacy.base_instructions(opts))
    end,
  },
}
