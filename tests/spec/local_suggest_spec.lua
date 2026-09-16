local config = require("agentify.config")
local context = require("agentify.context")
local engine = require("agentify.engine")
local h = require("tests.helpers")
local local_suggest = require("agentify.local_suggest")
local state = require("agentify.state")

local fixture_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/pnr_status_mweb_excerpt.tsx"

local function with_fixture(callback)
  local lines = vim.fn.readfile(fixture_path)
  return h.with_buffer(lines, function(bufnr)
    vim.bo[bufnr].filetype = "typescriptreact"
    return callback(bufnr)
  end)
end

local function build_ctx(bufnr, row, prefix)
  vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { prefix })
  vim.api.nvim_win_set_cursor(0, { row + 1, #prefix })
  return context.build(bufnr, config.normalize({}))
end

return {
  {
    name = "suggests repeated token suffixes from the PNRStatus excerpt",
    fn = function()
      with_fixture(function(bufnr)
        local ctx = build_ctx(bufnr, 2, "const value = useNavig")
        local suggestion = local_suggest.suggest(bufnr, ctx, config.normalize({}))

        h.ok(suggestion)
        h.eq("ate", suggestion.text)
        h.eq("buffer-token", suggestion.source)
      end)
    end,
  },
  {
    name = "suggests repeated line suffixes from the PNRStatus excerpt",
    fn = function()
      with_fixture(function(bufnr)
        local row = 23
        local ctx = build_ctx(bufnr, row, "      <HotelCrossSellContainer pnrResponse={pnrResp")
        local suggestion = local_suggest.suggest(bufnr, ctx, config.normalize({}))

        h.ok(suggestion)
        h.eq("onse} />", suggestion.text)
        h.eq("buffer-line", suggestion.source)
      end)
    end,
  },
  {
    name = "auto request uses local suggestion before Codex",
    fn = function()
      with_fixture(function(bufnr)
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

        local row = 23
        local prefix = "      <HotelCrossSellContainer pnrResponse={pnrResp"
        vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { prefix })
        vim.api.nvim_win_set_cursor(0, { row + 1, #prefix })

        local ok, reason = engine.request(bufnr, { manual = false })
        h.eq(true, ok)
        h.eq("local-suggestion", reason)
        h.eq(0, provider_calls)
        h.eq("onse} />", state.get_buffer(bufnr).suggestion.text)
      end)
    end,
  },
}
