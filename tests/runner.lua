local M = {}

local function repo_root()
  return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
end

function M.run()
  local files = vim.fn.globpath(repo_root() .. "/tests/spec", "*_spec.lua", false, true)
  table.sort(files)

  local total = 0
  local failures = {}

  for _, file in ipairs(files) do
    local spec = dofile(file)
    for _, case in ipairs(spec) do
      total = total + 1
      local ok, err = xpcall(case.fn, debug.traceback)
      if not ok then
        table.insert(failures, ("%s :: %s\n%s"):format(vim.fn.fnamemodify(file, ":t"), case.name, err))
      end
    end
  end

  if #failures > 0 then
    print(("FAILED %d/%d tests"):format(#failures, total))
    for _, failure in ipairs(failures) do
      print(failure)
    end
    vim.cmd(("cquit %d"):format(#failures))
    return
  end

  print(("PASSED %d tests"):format(total))
  vim.cmd("qa!")
end

return M

