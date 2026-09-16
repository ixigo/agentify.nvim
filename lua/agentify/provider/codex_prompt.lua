-- Backwards-compatible alias. The prompt builder now lives in agentify.provider.prompt
-- and is shared by every provider.
local prompt = require("agentify.provider.prompt")

local M = {}

function M.base_instructions(opts)
  return prompt.base_instructions(opts, opts.providers and opts.providers.codex or opts.codex)
end

M.build_completion_request = prompt.build_completion_request

return M
