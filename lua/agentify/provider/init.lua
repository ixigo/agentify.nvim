local auto = require("agentify.provider.auto")
local claude = require("agentify.provider.claude")
local codex = require("agentify.provider.codex")
local config = require("agentify.config")

local M = {}

M.registry = {
  claude = claude.new,
  codex = codex.new,
}

function M.create(opts)
  if opts.provider == "auto" then
    local candidates = {}
    for _, name in ipairs(config.provider_names) do
      candidates[#candidates + 1] = {
        name = name,
        provider = M.registry[name](opts),
      }
    end

    return auto.new(opts, candidates)
  end

  local factory = M.registry[opts.provider]
  if not factory then
    error(("agentify.nvim: unsupported provider %q"):format(tostring(opts.provider)))
  end

  return factory(opts)
end

return M
