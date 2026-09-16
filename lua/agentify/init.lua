local commands = require("agentify.commands")
local config = require("agentify.config")
local engine = require("agentify.engine")
local log = require("agentify.log")
local provider_factory = require("agentify.provider")
local state = require("agentify.state")

local M = {
  _setup_complete = false,
}

local function ensure_setup()
  if not M._setup_complete then
    M.setup({})
  end
end

function M.setup(opts)
  local resolved = config.normalize(opts)

  state.reset()
  log.clear()
  log.configure(resolved.logging)

  for _, message in ipairs(resolved.deprecations or {}) do
    log.warn("deprecated config: " .. message)
    vim.schedule(function()
      vim.notify("agentify.nvim: " .. message, vim.log.levels.WARN, { title = "agentify.nvim" })
    end)
  end

  if resolved.frontend == "lsp" and not require("agentify.inline_lsp").is_supported() then
    log.warn("frontend = 'lsp' requires Neovim 0.12+ (vim.lsp.inline_completion); falling back to extmark")
    resolved.frontend = "extmark"
  end

  M.opts = resolved
  M.provider = provider_factory.create(resolved)

  engine.setup(resolved, M.provider)

  if resolved.frontend == "lsp" then
    require("agentify.inline_lsp").setup(resolved, {
      compute = engine.compute,
    })
  end

  commands.setup({
    status = function(callback)
      engine.status(callback)
    end,
    suggest = function()
      engine.request(0, { manual = true })
    end,
    reset_budget = function()
      return engine.reset_budget()
    end,
  })

  M._setup_complete = true
end

function M.suggest()
  ensure_setup()
  return engine.request(0, { manual = true })
end

function M.accept()
  ensure_setup()
  return engine.accept(0)
end

function M.accept_word()
  ensure_setup()
  return engine.accept_word(0)
end

function M.accept_line()
  ensure_setup()
  return engine.accept_line(0)
end

function M.dismiss()
  ensure_setup()
  return engine.dismiss(0)
end

function M.has_suggestion()
  ensure_setup()
  return engine.has_suggestion(0)
end

function M.reset_budget()
  ensure_setup()
  return engine.reset_budget()
end

function M.status(callback)
  ensure_setup()
  return engine.status(callback)
end

return M
