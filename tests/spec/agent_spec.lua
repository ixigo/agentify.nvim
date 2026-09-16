local agent = require("agentify.agent")
local config = require("agentify.config")
local h = require("tests.helpers")

local fixtures = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures"
local fake = fixtures .. "/fake_claude.sh"

local function make_opts(overrides)
  local opts = config.normalize(vim.tbl_deep_extend("force", {
    providers = { claude = { command = { fake } } },
    budget = { notify = false },
  }, overrides or {}))
  -- Agent runs consult the engine budget; earlier specs may have left it paused.
  require("agentify.engine").budget = require("agentify.budget").new(opts)
  return opts
end

local function with_diagnostics(list, fn)
  local original = vim.diagnostic.get
  vim.diagnostic.get = function()
    return list
  end
  local ok, err = pcall(fn)
  vim.diagnostic.get = original
  if not ok then
    error(err, 0)
  end
end

local function wait_for(predicate)
  return vim.wait(5000, predicate, 20)
end

return {
  {
    name = "builds a tool-enabled command; only fix gets Edit and acceptEdits",
    fn = function()
      local opts = make_opts({ agent = { extra_args = { "--add-dir", "/tmp" } } })

      local fix = table.concat(agent.build_command(opts, "fix", "PROMPT"), " ")
      h.match("^" .. vim.pesc(fake) .. " %-p ", fix)
      h.match("%-%-output%-format stream%-json", fix)
      h.match("%-%-model sonnet", fix)
      h.match("%-%-max%-turns 12", fix)
      h.match("%-%-tools Read,Edit,Grep,Glob", fix)
      h.match("%-%-permission%-mode acceptEdits", fix)
      h.match("%-%-effort medium", fix)
      h.match("%-%-add%-dir /tmp PROMPT$", fix)
      h.match("smallest correct change", fix)
      h.ok(not fix:find("--input-format", 1, true), "agent runs are one-shot")

      local explain = table.concat(agent.build_command(opts, "explain", "PROMPT"), " ")
      h.match("%-%-tools Read,Grep,Glob", explain)
      h.ok(not explain:find("acceptEdits", 1, true), "explain must not auto-accept edits")
      h.ok(not explain:find("Edit,", 1, true), "explain must not get the Edit tool")
      h.match("Do not modify any file", explain)
    end,
  },
  {
    name = "fix_request needs a diagnostic and describes it",
    fn = function()
      h.with_buffer({ "const a = 1;", "const name = user.name;" }, function(bufnr)
        vim.api.nvim_buf_set_name(bufnr, "/repo/src/app.ts")
        with_diagnostics({}, function()
          local prompt, reason = agent.fix_request(bufnr, 1, "/repo")
          h.eq(nil, prompt)
          h.match("no diagnostic", reason)
        end)

        with_diagnostics({
          { lnum = 1, col = 13, severity = vim.diagnostic.severity.WARN, message = "unused", source = "eslint" },
          { lnum = 1, col = 13, severity = vim.diagnostic.severity.ERROR, message = "'user' is possibly 'undefined'.", source = "tsserver", code = 18048 },
        }, function()
          local prompt, info = agent.fix_request(bufnr, 1, "/repo")
          h.match("^File: src/app%.ts\nLine 2: const name = user%.name;", prompt)
          h.match("%- error %(tsserver%) %[18048%]: 'user' is possibly 'undefined'%.\n%- warning %(eslint%): unused", prompt)
          h.match("Fix these diagnostics in src/app%.ts", prompt)
          h.eq("src/app.ts", info.path)
          h.match("^error %(tsserver%)", info.summary)
        end)
      end)
    end,
  },
  {
    name = "explain_request embeds the selected lines with the filetype",
    fn = function()
      h.with_buffer({ "one", "two", "three", "four" }, function(bufnr)
        vim.api.nvim_buf_set_name(bufnr, "/repo/lib/x.lua")
        vim.bo[bufnr].filetype = "lua"
        local prompt, info = agent.explain_request(bufnr, 3, 2, "/repo")
        h.match("^File: lib/x%.lua %(lines 2%-3%)\n\n```lua\ntwo\nthree\n```", prompt)
        h.eq(2, info.first)
        h.eq(3, info.last)
      end)
    end,
  },
  {
    name = "describe_tool names the target",
    fn = function()
      h.eq("Edit src/app.ts", agent.describe_tool("Edit", { file_path = "src/app.ts" }))
      h.eq("Grep TODO", agent.describe_tool("Grep", { pattern = "TODO" }))
      h.eq("Glob", agent.describe_tool("Glob", {}))
    end,
  },
  {
    name = "runs a task against the fake CLI, streaming text and tools into hooks",
    fn = function()
      local opts = make_opts()
      local texts, tools, status, done = {}, {}, nil, nil
      local ok, err = agent.run(opts, "fix", "PROMPT", vim.fn.getcwd(), {
        on_status = function(text)
          status = text
        end,
        on_text = function(text)
          texts[#texts + 1] = text
        end,
        on_tool = function(name, input)
          tools[#tools + 1] = agent.describe_tool(name, input)
        end,
        on_done = function(result)
          done = result
        end,
      })
      h.eq(true, ok, tostring(err))

      -- a second task cannot start while one runs
      local again, again_err = agent.run(opts, "explain", "P", vim.fn.getcwd(), {})
      h.eq(false, again)
      h.match("already running", again_err)

      h.ok(wait_for(function()
        return done ~= nil
      end), "expected the task to finish")
      h.eq(true, done.ok)
      h.eq("success", done.subtype)
      h.match("optional chaining", done.text)
      h.eq({ "Read src/app.ts", "Edit src/app.ts" }, done.tools)
      h.eq(3, done.turns)
      h.match("running with claude%-sonnet%-5", status)
      h.eq({ "Read src/app.ts", "Edit src/app.ts" }, tools)
      h.eq("Looking at the diagnostic.", texts[1])
      h.eq(nil, agent.running)
    end,
  },
  {
    name = "reports a failed run",
    fn = function()
      vim.env.FAKE_CLAUDE_MODE = "agent-fail"
      local done
      local ok = agent.run(make_opts(), "explain", "P", vim.fn.getcwd(), {
        on_done = function(result)
          done = result
        end,
      })
      h.eq(true, ok)
      h.ok(wait_for(function()
        return done ~= nil
      end))
      h.eq(false, done.ok)
      h.eq("error_max_turns", done.subtype)
      h.match("max turns", done.text)
      vim.env.FAKE_CLAUDE_MODE = nil
    end,
  },
  {
    name = "explain command streams into the panel and finishes",
    fn = function()
      local opts = make_opts()
      h.with_buffer({ "local function add(a, b)", "  return a + b", "end" }, function(bufnr)
        vim.api.nvim_buf_set_name(bufnr, vim.fn.getcwd() .. "/lua/example.lua")
        vim.bo[bufnr].filetype = "lua"

        local ok, err = agent.explain(opts, bufnr, 1, 3)
        h.eq(true, ok, tostring(err))
        h.ok(wait_for(function()
          return agent.running == nil
        end), "explain should finish")

        local lines = table.concat(agent.panel_lines(), "\n")
        h.match("# Explain · lua/example%.lua:1%-3", lines)
        h.match("▸ Read src/app%.ts", lines)
        h.match("Added optional chaining", lines)
        h.match("No other lines changed%.", lines)
        h.match("✓ done in %d+s", lines)
        h.ok(vim.api.nvim_win_is_valid(agent.panel.winid), "panel window should be open")
        agent.panel_close()
      end)
    end,
  },
  {
    name = "fix command refuses without a diagnostic and runs with one",
    fn = function()
      local opts = make_opts()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      h.with_buffer({ "const name = user.name;" }, function(bufnr)
        -- a real path so the pre-fix save succeeds; the buffer stays modified on purpose
        vim.api.nvim_buf_set_name(bufnr, dir .. "/app.ts")
        vim.bo[bufnr].filetype = "typescript"
        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        with_diagnostics({}, function()
          local ok, reason = agent.fix(opts, bufnr)
          h.eq(false, ok)
          h.match("no diagnostic", reason)
        end)

        with_diagnostics({
          { lnum = 0, col = 13, severity = vim.diagnostic.severity.ERROR, message = "'user' is possibly 'undefined'." },
        }, function()
          local ok, err = agent.fix(opts, bufnr)
          h.eq(true, ok, tostring(err))
          h.ok(wait_for(function()
            return agent.running == nil
          end))
          h.eq(false, vim.bo[bufnr].modified, "buffer should have been saved before the fix")
          local lines = table.concat(agent.panel_lines(), "\n")
          h.match("# Fix · app%.ts:1", lines)
          h.match("possibly 'undefined'", lines)
          h.match("▸ Edit src/app%.ts", lines)
          h.match("✓ done in %d+s, 2 tool call%(s%)", lines)
          agent.panel_close()
        end)
      end)
    end,
  },
}
