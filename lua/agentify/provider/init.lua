local codex = require("agentify.provider.codex")

local M = {}

function M.create(opts)
  if opts.provider == "codex" then
    return codex.new(opts)
  end

  error(("agentify.nvim: unsupported provider %q"):format(tostring(opts.provider)))
end

return M

