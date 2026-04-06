local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local agentify = require("agentify")

agentify.setup({
  logging = {
    level = "debug",
  },
})

local status_done = false
local status_report = nil

agentify.status(function(report)
  status_report = report
  status_done = true
end)

vim.wait(15000, function()
  return status_done
end)

if not status_report then
  print("status probe timed out")
  vim.cmd("cquit 1")
  return
end

print(vim.inspect(status_report))

if not status_report.ready then
  vim.cmd("cquit 1")
  return
end

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "javascript"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "function demo(foo) {",
  "  const result = foo",
  "}",
})
vim.api.nvim_win_set_cursor(0, { 2, #"  const result = foo" })
vim.cmd("startinsert")

local done = false

agentify.suggest()

vim.wait(20000, function()
  done = agentify.has_suggestion()
  return done
end)

if not done then
  print("suggestion probe timed out")
  local post_report_done = false
  agentify.status(function(report)
    print(vim.inspect(report))
    post_report_done = true
  end)
  vim.wait(5000, function()
    return post_report_done
  end)
  vim.cmd("cquit 1")
  return
end

print("suggestion:", vim.inspect(require("agentify.actions").get(bufnr)))
vim.cmd("qa!")
