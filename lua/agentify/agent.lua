-- Agentic commands: :AgentifyFix and :AgentifyExplain.
--
-- Ghost text is where a chat model is weakest; tools are where Claude Code is strongest.
-- These run a fresh `claude -p` with a small tool set in the project root, stream the
-- transcript into a panel, and (for fix) reload buffers when the edit lands.
local log = require("agentify.log")
local ndjson = require("agentify.transport.ndjson")

local M = {
  panel = { bufnr = nil, winid = nil, partial = "" },
  running = nil,
}

local function resolve_bufnr(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

local function notify(message, level)
  vim.notify("agentify.nvim: " .. message, level or vim.log.levels.INFO, { title = "agentify.nvim" })
end

function M.project_root(bufnr)
  local ok, root = pcall(vim.fs.root, bufnr, { ".git" })
  if ok and root then
    return root
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" then
    return vim.fn.fnamemodify(name, ":p:h")
  end

  return (vim.uv or vim.loop).cwd()
end

local function relative_path(path, root)
  if root and path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return path
end

function M.system_prompt(kind)
  if kind == "fix" then
    return table.concat({
      "You are fixing one diagnostic in a file the user has open in Neovim.",
      "Make the smallest correct change with the Edit tool. Read the file first.",
      "Do not reformat unrelated code, do not create new files, and do not run commands.",
      "Stay inside the project directory.",
      "When done, reply with one or two sentences describing exactly what you changed.",
    }, "\n")
  end

  return table.concat({
    "You are explaining code to a developer inside Neovim.",
    "Use Read, Grep, and Glob to look up referenced symbols when that makes the explanation concrete.",
    "Cover what the code does, notable behaviours, and pitfalls. Skip generic advice.",
    "Answer in Markdown, under 250 words. Do not modify any file.",
  }, "\n")
end

function M.build_command(opts, kind, prompt)
  local aopts = opts.agent
  local command = vim.deepcopy(opts.providers.claude.command)
  local tools = kind == "fix" and aopts.fix.tools or aopts.explain.tools

  local args = {
    "-p",
    "--output-format", "stream-json",
    "--verbose",
    "--model", aopts.model,
    "--max-turns", tostring(aopts.max_turns),
    "--no-session-persistence",
    "--disable-slash-commands",
    "--setting-sources", "",
    "--strict-mcp-config",
    "--mcp-config", '{"mcpServers":{}}',
    "--tools", table.concat(tools, ","),
    "--append-system-prompt", M.system_prompt(kind),
  }

  if aopts.effort and aopts.effort ~= "" then
    vim.list_extend(args, { "--effort", aopts.effort })
  end

  if kind == "fix" then
    vim.list_extend(args, { "--permission-mode", "acceptEdits" })
  end

  for _, extra in ipairs(aopts.extra_args or {}) do
    args[#args + 1] = extra
  end

  args[#args + 1] = prompt
  vim.list_extend(command, args)
  return command
end

local severity_names = {
  [vim.diagnostic.severity.ERROR] = "error",
  [vim.diagnostic.severity.WARN] = "warning",
  [vim.diagnostic.severity.INFO] = "info",
  [vim.diagnostic.severity.HINT] = "hint",
}

-- Builds the fix prompt for the diagnostics on `row` (0-based). Returns nil when there are none.
function M.fix_request(bufnr, row, root)
  bufnr = resolve_bufnr(bufnr)
  local diagnostics = vim.diagnostic.get(bufnr, { lnum = row })
  if not diagnostics or #diagnostics == 0 then
    return nil, "no diagnostic on this line"
  end

  table.sort(diagnostics, function(a, b)
    return (a.severity or 4) < (b.severity or 4)
  end)

  local path = relative_path(vim.api.nvim_buf_get_name(bufnr), root)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local items = {}
  for _, diagnostic in ipairs(diagnostics) do
    local source = diagnostic.source and (" (" .. diagnostic.source .. ")") or ""
    local code = diagnostic.code and (" [" .. tostring(diagnostic.code) .. "]") or ""
    items[#items + 1] = ("- %s%s%s: %s"):format(
      severity_names[diagnostic.severity] or "diagnostic",
      source,
      code,
      (diagnostic.message or ""):gsub("%s+$", "")
    )
  end

  local prompt = table.concat({
    ("File: %s"):format(path),
    ("Line %d: %s"):format(row + 1, line),
    "",
    "Diagnostics on this line:",
    table.concat(items, "\n"),
    "",
    ("Fix these diagnostics in %s with the smallest correct change."):format(path),
  }, "\n")

  return prompt, {
    path = path,
    row = row,
    summary = items[1]:gsub("^%- ", ""),
  }
end

-- Builds the explain prompt for lines `first`..`last` (1-based, inclusive).
function M.explain_request(bufnr, first, last, root)
  bufnr = resolve_bufnr(bufnr)
  if first > last then
    first, last = last, first
  end

  local path = relative_path(vim.api.nvim_buf_get_name(bufnr), root)
  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  local filetype = vim.bo[bufnr].filetype or ""

  local prompt = table.concat({
    ("File: %s (lines %d-%d)"):format(path, first, last),
    "",
    "```" .. filetype,
    table.concat(lines, "\n"),
    "```",
    "",
    "Explain this code.",
  }, "\n")

  return prompt, { path = path, first = first, last = last }
end

-- One line describing a tool call for the panel.
function M.describe_tool(name, input)
  input = input or {}
  local target = input.file_path or input.path or input.pattern or input.command or input.query
  if type(target) == "string" and target ~= "" then
    return ("%s %s"):format(name, target)
  end
  return name
end

------------------------------------------------------------------------------------------
-- Panel
------------------------------------------------------------------------------------------

function M.panel_open(opts)
  local panel = M.panel
  if not panel.bufnr or not vim.api.nvim_buf_is_valid(panel.bufnr) then
    panel.bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(panel.bufnr, "agentify://agent")
    vim.bo[panel.bufnr].buftype = "nofile"
    vim.bo[panel.bufnr].bufhidden = "hide"
    vim.bo[panel.bufnr].swapfile = false
    vim.bo[panel.bufnr].filetype = "markdown"
    vim.keymap.set("n", "q", function()
      M.panel_close()
    end, { buffer = panel.bufnr, nowait = true, silent = true })
  end

  if not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
    local current = vim.api.nvim_get_current_win()
    vim.cmd(("botright %dsplit"):format(opts.agent.panel_height))
    panel.winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(panel.winid, panel.bufnr)
    vim.wo[panel.winid].wrap = true
    vim.wo[panel.winid].number = false
    vim.wo[panel.winid].relativenumber = false
    vim.wo[panel.winid].signcolumn = "no"
    vim.api.nvim_set_current_win(current)
  end

  return panel.bufnr
end

function M.panel_close()
  local panel = M.panel
  if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    vim.api.nvim_win_close(panel.winid, true)
  end
  panel.winid = nil
end

function M.panel_reset(lines)
  local panel = M.panel
  panel.partial = ""
  if panel.bufnr and vim.api.nvim_buf_is_valid(panel.bufnr) then
    vim.api.nvim_buf_set_lines(panel.bufnr, 0, -1, false, lines or {})
  end
end

local function panel_scroll()
  local panel = M.panel
  if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    local count = vim.api.nvim_buf_line_count(panel.bufnr)
    pcall(vim.api.nvim_win_set_cursor, panel.winid, { count, 0 })
  end
end

function M.panel_append_line(line)
  local panel = M.panel
  if not panel.bufnr or not vim.api.nvim_buf_is_valid(panel.bufnr) then
    return
  end

  if panel.partial ~= "" then
    local count = vim.api.nvim_buf_line_count(panel.bufnr)
    vim.api.nvim_buf_set_lines(panel.bufnr, count - 1, count, false, { panel.partial })
    panel.partial = ""
  end

  vim.api.nvim_buf_set_lines(panel.bufnr, -1, -1, false, vim.split(line, "\n", { plain = true }))
  panel_scroll()
end

-- Appends streamed text, joining fragments until a newline arrives.
function M.panel_append(text)
  local panel = M.panel
  if not panel.bufnr or not vim.api.nvim_buf_is_valid(panel.bufnr) then
    return
  end

  local combined = panel.partial .. text
  local pieces = vim.split(combined, "\n", { plain = true })
  panel.partial = table.remove(pieces)

  local count = vim.api.nvim_buf_line_count(panel.bufnr)
  local last = vim.api.nvim_buf_get_lines(panel.bufnr, count - 1, count, false)[1] or ""
  if #pieces > 0 then
    if last == "" and count == 1 then
      vim.api.nvim_buf_set_lines(panel.bufnr, 0, 1, false, pieces)
    else
      vim.api.nvim_buf_set_lines(panel.bufnr, -1, -1, false, pieces)
    end
  end

  if panel.partial ~= "" then
    vim.api.nvim_buf_set_lines(panel.bufnr, -1, -1, false, { panel.partial })
    -- keep partial as a pending line: it is replaced when more text arrives
    local total = vim.api.nvim_buf_line_count(panel.bufnr)
    M.panel.pending_row = total - 1
  end
  panel_scroll()
end

function M.panel_lines()
  local panel = M.panel
  if not panel.bufnr or not vim.api.nvim_buf_is_valid(panel.bufnr) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(panel.bufnr, 0, -1, false)
end

------------------------------------------------------------------------------------------
-- Runner
------------------------------------------------------------------------------------------

-- Runs one agent task. `hooks`: on_status(text), on_text(text), on_tool(name, input),
-- on_done({ ok, text, subtype, usage, tools }).
function M.run(opts, kind, prompt, root, hooks)
  hooks = hooks or {}

  if M.running then
    return false, "an agent task is already running"
  end

  local engine_ok, engine = pcall(require, "agentify.engine")
  if engine_ok and engine.budget then
    local allowed, reason = engine.budget:allow(os.time(), true)
    if not allowed then
      return false, ("model tier is paused (%s); try again later or run :AgentifyBudgetReset"):format(reason)
    end
    engine.budget:count("agent")
  end

  local transport = ndjson.new({
    command = M.build_command(opts, kind, prompt),
    env_blocklist = opts.auth.strip_env,
    cwd = root,
    label = "claude agent",
  })

  local task = {
    kind = kind,
    transport = transport,
    text = "",
    tools = {},
    done = false,
    started_at = os.time(),
  }

  local function finish(result)
    if task.done then
      return
    end
    task.done = true
    M.running = nil
    transport:stop()
    if hooks.on_done then
      hooks.on_done(result)
    end
  end

  transport:on_line(function(message)
    local kind_of = message.type
    if kind_of == "system" and message.subtype == "init" then
      if hooks.on_status then
        hooks.on_status(("running with %s"):format(message.model or opts.agent.model))
      end
      return
    end

    if kind_of == "assistant" then
      local content = message.message and message.message.content or {}
      for _, block in ipairs(content) do
        if block.type == "text" and block.text and block.text ~= "" then
          task.text = task.text .. block.text
          if hooks.on_text then
            hooks.on_text(block.text)
          end
        elseif block.type == "tool_use" then
          task.tools[#task.tools + 1] = M.describe_tool(block.name, block.input)
          if hooks.on_tool then
            hooks.on_tool(block.name, block.input)
          end
        end
      end
      return
    end

    if kind_of == "result" then
      local ok = message.subtype == "success" and not message.is_error
      finish({
        ok = ok,
        subtype = message.subtype,
        text = (type(message.result) == "string" and message.result ~= "") and message.result or task.text,
        usage = message.usage,
        cost = message.total_cost_usd,
        turns = message.num_turns,
        tools = task.tools,
        duration_s = os.time() - task.started_at,
      })
      return
    end
  end)

  transport:on_exit(function(_, err)
    finish({ ok = false, subtype = "exited", text = err or "claude exited", tools = task.tools })
  end)

  local started, err = transport:start()
  if not started then
    return false, err
  end
  transport:close_stdin()

  M.running = task
  log.info("agent task started", { kind = kind, root = root })
  return true, nil
end

function M.cancel()
  local task = M.running
  if not task then
    return false
  end
  task.done = true
  M.running = nil
  task.transport:stop()
  M.panel_append_line("✗ cancelled")
  return true
end

------------------------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------------------------

local function common_hooks(opts, header)
  M.panel_open(opts)
  M.panel_reset({ header, "" })

  return {
    on_status = function(text)
      M.panel_append_line(("_%s_"):format(text))
      M.panel_append_line("")
    end,
    on_tool = function(name, input)
      M.panel_append_line(("▸ %s"):format(M.describe_tool(name, input)))
    end,
    on_text = function(text)
      M.panel_append(text)
    end,
  }
end

function M.fix(opts, bufnr)
  bufnr = resolve_bufnr(bufnr)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local root = M.project_root(bufnr)

  local prompt, info = M.fix_request(bufnr, row, root)
  if not prompt then
    notify(info, vim.log.levels.WARN)
    return false, info
  end

  -- The agent edits the file on disk, so the buffer must be saved first.
  if vim.bo[bufnr].modified then
    local saved = pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("silent update")
    end)
    if not saved then
      notify("could not save the buffer before fixing", vim.log.levels.ERROR)
      return false, "save failed"
    end
  end

  local hooks = common_hooks(opts, ("# Fix · %s:%d"):format(info.path, row + 1))
  M.panel_append_line(info.summary)
  M.panel_append_line("")

  hooks.on_done = function(result)
    M.panel_append_line("")
    if result.ok then
      M.panel_append_line(("✓ done in %ds, %d tool call(s)"):format(result.duration_s or 0, #(result.tools or {})))
      vim.cmd("silent! checktime")
      notify(result.text ~= "" and result.text or "fix applied", vim.log.levels.INFO)
    else
      M.panel_append_line(("✗ %s: %s"):format(result.subtype or "failed", result.text or ""))
      notify(("fix failed: %s"):format(result.text or result.subtype), vim.log.levels.ERROR)
    end
  end

  local ok, err = M.run(opts, "fix", prompt, root, hooks)
  if not ok then
    M.panel_append_line("✗ " .. err)
    notify(err, vim.log.levels.WARN)
  end
  return ok, err
end

function M.explain(opts, bufnr, first, last)
  bufnr = resolve_bufnr(bufnr)
  local root = M.project_root(bufnr)

  if not first or not last then
    local mode = vim.api.nvim_get_mode().mode
    if mode:match("^[vV\22]") then
      first, last = vim.fn.line("v"), vim.fn.line(".")
    else
      first = vim.api.nvim_win_get_cursor(0)[1]
      last = first
    end
  end

  local prompt, info = M.explain_request(bufnr, first, last, root)
  local hooks = common_hooks(opts, ("# Explain · %s:%d-%d"):format(info.path, info.first, info.last))

  hooks.on_done = function(result)
    M.panel_append_line("")
    if result.ok then
      M.panel_append_line(("✓ done in %ds"):format(result.duration_s or 0))
    else
      M.panel_append_line(("✗ %s: %s"):format(result.subtype or "failed", result.text or ""))
      notify(("explain failed: %s"):format(result.text or result.subtype), vim.log.levels.ERROR)
    end
  end

  local ok, err = M.run(opts, "explain", prompt, root, hooks)
  if not ok then
    M.panel_append_line("✗ " .. err)
    notify(err, vim.log.levels.WARN)
  end
  return ok, err
end

return M
