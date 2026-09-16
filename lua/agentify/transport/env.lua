-- Builds the environment for spawned CLI processes with billing-related keys removed,
-- so the CLIs fall back to their subscription (claude.ai / ChatGPT) logins.
local M = {}

local function blocked_set(blocklist)
  local blocked = {}
  for _, key in ipairs(blocklist or {}) do
    blocked[key] = true
  end
  return blocked
end

-- Map form, for vim.system({ env = ..., clear_env = true }).
function M.build_map(blocklist)
  local blocked = blocked_set(blocklist)
  local env = {}

  for key, value in pairs(vim.fn.environ()) do
    if not blocked[key] then
      env[key] = value
    end
  end

  return env
end

-- List form ("KEY=VALUE"), for uv.spawn({ env = ... }).
-- Returns nil when nothing is blocked so the child simply inherits.
function M.build(blocklist)
  if not blocklist or #blocklist == 0 then
    return nil
  end

  local env = {}
  for key, value in pairs(M.build_map(blocklist)) do
    env[#env + 1] = key .. "=" .. value
  end

  return env
end

return M
