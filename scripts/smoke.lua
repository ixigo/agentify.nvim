local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local agentify = require("agentify")
local actions = require("agentify.actions")
local engine = require("agentify.engine")

agentify.setup({
  logging = {
    level = "debug",
  },
})

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "javascript"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "function first(foo) {",
  "  const result = foo;",
  "  return result;",
  "}",
  "",
  "function second(foo) {",
  "  const result = fo",
  "}",
})
vim.api.nvim_win_set_cursor(0, { 7, #"  const result = fo" })
vim.cmd("startinsert")

local ok, reason = engine.request(bufnr, { manual = false })
if not ok then
  print("request failed:", reason)
  vim.cmd("cquit 1")
  return
end

local done = vim.wait(2000, function()
  return agentify.has_suggestion()
end)

if not done then
  print("smoke suggestion timed out")
  print(vim.inspect(require("agentify.state").get_buffer(bufnr)))
  vim.cmd("cquit 1")
  return
end

local suggestion = actions.get(bufnr)
print("reason:", reason)
print("suggestion:", vim.inspect(suggestion))

if suggestion.source ~= "buffer-line" or not suggestion.text:match("^o+;$") then
  print("unexpected suggestion payload")
  vim.cmd("cquit 1")
  return
end

vim.cmd("qa!")
