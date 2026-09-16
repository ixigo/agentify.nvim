local config = require("agentify.config")
local engine = require("agentify.engine")
local h = require("tests.helpers")
local prompt = require("agentify.provider.prompt")
local repo_context = require("agentify.repo_context")
local state = require("agentify.state")

local fixtures = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures"
local fake = fixtures .. "/fake_agentify.sh"

-- Creates a throwaway indexed project: <root>/.agentify/index.db plus two source files.
local function make_root()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/.agentify", "p")
  vim.fn.mkdir(root .. "/src", "p")
  vim.fn.writefile({ "" }, root .. "/.agentify/index.db")
  vim.fn.writefile({
    "// utilities",
    "export function formatPrice(amount: number, currency = 'INR') {",
    "  return `${currency} ${amount.toFixed(2)}`;",
    "}",
    "export const unrelated = 1;",
  }, root .. "/src/util.ts")
  vim.fn.writefile({
    "import { formatPrice } from './util';",
    "",
    "const label = formatPrice(total, 'USD');",
  }, root .. "/src/app.ts")
  vim.fn.writefile({ "", "", "", "", "", "", "", "", "const x = formatPrice(1);" }, root .. "/src/current.ts")
  return root
end

local function opts_with(overrides)
  return config.normalize(vim.tbl_deep_extend("force", {
    repo_context = { command = { fake } },
  }, overrides or {}))
end

local function ctx_for(root, prefix)
  return {
    filepath = root .. "/src/current.ts",
    filetype = "typescript",
    line_prefix = prefix,
    line_suffix = "",
    before_lines = {},
    after_lines = {},
    expandtab = true,
    tabstop = 2,
    shiftwidth = 2,
  }
end

return {
  {
    name = "finds the index root by walking up from the file",
    fn = function()
      repo_context.reset()
      local root = make_root()
      h.eq(root, repo_context.find_root(root .. "/src/current.ts"))
      h.eq(root, repo_context.find_root(root .. "/src"))
      h.eq(nil, repo_context.find_root(vim.fn.tempname() .. "/nowhere.ts"))
      h.eq(nil, repo_context.find_root(""))
    end,
  },
  {
    name = "picks identifiers near the cursor, skipping keywords and the partial token",
    fn = function()
      local opts = opts_with().repo_context
      h.eq({ "formatPrice", "total" }, repo_context.candidate_symbols({ line_prefix = "const label = formatPrice(total, cur" }, opts))
      h.eq({ "formatPrice" }, repo_context.candidate_symbols({ line_prefix = "  return formatPrice(" }, opts))
      h.eq({}, repo_context.candidate_symbols({ line_prefix = "const x = " }, opts))
      h.eq({ "items" }, repo_context.candidate_symbols({
        line_prefix = "const convertArrayToString = (items) =>",
        intent = { symbol_name = "convertArrayToString" },
      }, opts))
    end,
  },
  {
    name = "collects a definition and call sites from the fake index, then serves from cache",
    fn = function()
      repo_context.reset()
      local root = make_root()
      local opts = opts_with()
      local result

      repo_context.collect(ctx_for(root, "  return formatPrice("), opts, function(repo)
        result = repo or false
      end)
      h.ok(vim.wait(5000, function()
        return result ~= nil
      end, 20), "expected repo context")
      h.ok(result, "expected a non-nil repo context")

      h.eq(root, result.root)
      h.eq(1, #result.symbols)
      local entry = result.symbols[1]
      h.eq("formatPrice", entry.name)
      h.eq("src/util.ts", entry.definition.file)
      h.eq(2, entry.definition.start_line)
      h.eq({
        "export function formatPrice(amount: number, currency = 'INR') {",
        "  return `${currency} ${amount.toFixed(2)}`;",
        "}",
      }, entry.definition.lines)
      -- call sites come first, the current file is excluded
      h.eq(2, #entry.references)
      h.eq("src/app.ts:3", ("%s:%d"):format(entry.references[1].file, entry.references[1].line))
      h.match("formatPrice%(total", entry.references[1].text)
      h.eq(1, entry.references[2].line)

      -- second collect is synchronous (cache hit)
      local sync_result
      repo_context.collect(ctx_for(root, "  return formatPrice("), opts, function(repo)
        sync_result = repo
      end)
      h.eq("formatPrice", sync_result.symbols[1].name)
      h.eq(1, repo_context.stats.hits)
      h.eq(1, repo_context.stats.lookups)
    end,
  },
  {
    name = "continues without context when lookups exceed timeout_ms, then caches the late answer",
    fn = function()
      repo_context.reset()
      local root = make_root()
      vim.env.FAKE_AGENTIFY_DELAY = "1"
      local opts = opts_with({ repo_context = { timeout_ms = 60 } })

      local result, called_at
      local started = vim.uv.hrtime()
      repo_context.collect(ctx_for(root, "formatPrice("), opts, function(repo)
        result = repo or false
        called_at = (vim.uv.hrtime() - started) / 1e6
      end)
      h.ok(vim.wait(2000, function()
        return result ~= nil
      end, 10))
      h.eq(false, result)
      h.ok(called_at < 700, ("timeout callback took %.0fms"):format(called_at or -1))
      h.eq(1, repo_context.stats.timeouts)

      -- the late answer still lands in the cache
      h.ok(vim.wait(4000, function()
        return repo_context.stats.misses == 1
      end, 20))
      vim.env.FAKE_AGENTIFY_DELAY = nil

      local cached
      repo_context.collect(ctx_for(root, "formatPrice("), opts, function(repo)
        cached = repo
      end)
      h.eq("formatPrice", cached.symbols[1].name)
    end,
  },
  {
    name = "returns nil synchronously without an index, symbols, or when disabled",
    fn = function()
      repo_context.reset()
      local opts = opts_with()
      local calls = 0
      repo_context.collect(ctx_for(vim.fn.tempname(), "formatPrice("), opts, function(repo)
        calls = calls + 1
        h.eq(nil, repo)
      end)
      h.eq(1, calls)

      local root = make_root()
      repo_context.collect(ctx_for(root, "const x = "), opts, function(repo)
        calls = calls + 1
        h.eq(nil, repo)
      end)
      h.eq(2, calls)

      repo_context.collect(ctx_for(root, "formatPrice("), opts_with({ repo_context = { enabled = false } }), function(repo)
        calls = calls + 1
        h.eq(nil, repo)
      end)
      h.eq(3, calls)
    end,
  },
  {
    name = "renders repo definitions and call sites into the prompt",
    fn = function()
      local opts = opts_with()
      local ctx = ctx_for("/tmp/x", "const label = formatPrice(")
      ctx.repo = {
        root = "/tmp/x",
        symbols = {
          {
            name = "formatPrice",
            definition = { file = "src/util.ts", start_line = 2, lines = { "export function formatPrice(amount) {", "}" } },
            references = { { file = "src/app.ts", line = 3, text = "const label = formatPrice(total, 'USD');" } },
          },
        },
      }

      local request = prompt.build_completion_request(ctx, opts)
      h.match("REPO_DEFINITIONS:\n%-%- formatPrice %(src/util%.ts:2%)\nexport function formatPrice%(amount%) {", request)
      h.match("REPO_CALL_SITES:\nsrc/app%.ts:3: const label = formatPrice%(total, 'USD'%);", request)

      ctx.repo = nil
      h.ok(not prompt.build_completion_request(ctx, opts):find("REPO_", 1, true))
    end,
  },
  {
    name = "engine passes repo context to the provider and honours cancel while collecting",
    fn = function()
      repo_context.reset()
      local root = make_root()
      local original_get_mode = vim.api.nvim_get_mode
      vim.api.nvim_get_mode = function()
        return { mode = "i", blocking = false }
      end

      local seen_ctx
      local provider = {
        complete = function(_, ctx)
          seen_ctx = ctx
          return { cancel = function() end }
        end,
        status = function(_, cb)
          cb({ provider = "fake", cli = { available = false, command = {} }, transport = {}, thread = {} })
        end,
        warmup = function(_, cb)
          if cb then
            cb(true)
          end
        end,
      }

      state.reset()
      engine.setup(opts_with({ budget = { notify = false } }), provider)

      local ok, err = pcall(h.with_buffer, { "const label = formatPrice(" }, function(bufnr)
        vim.api.nvim_buf_set_name(bufnr, root .. "/src/current.ts")
        vim.bo[bufnr].filetype = "typescript"
        vim.cmd("startinsert")
        vim.api.nvim_win_set_cursor(0, { 1, #"const label = formatPrice(" })

        h.eq(true, (engine.request(bufnr, { manual = true })))
        h.ok(vim.wait(5000, function()
          return seen_ctx ~= nil
        end, 20), "provider should be called after collection")
        h.eq("formatPrice", seen_ctx.repo.symbols[1].name)

        -- cancel while a fresh (uncached) lookup is in flight: provider must not be called
        repo_context.reset()
        seen_ctx = nil
        vim.env.FAKE_AGENTIFY_DELAY = "1"
        h.eq(true, (engine.request(bufnr, { manual = true })))
        engine.cancel_request(bufnr, "test")
        vim.wait(1500, function()
          return false
        end, 50)
        h.eq(nil, seen_ctx)
        vim.env.FAKE_AGENTIFY_DELAY = nil
      end)

      vim.api.nvim_get_mode = original_get_mode
      if not ok then
        error(err, 0)
      end
    end,
  },
  {
    name = "status reports the index root and cache",
    fn = function()
      local commands = require("agentify.commands")
      local base = {
        provider = "claude", ready = true, cli = { available = true, command = { "claude" } },
        transport = {}, thread = {}, buffer = { filetype = "lua", enabled = true },
      }
      local text = table.concat(commands.format_status(vim.tbl_extend("force", base, {
        repo_context = { enabled = true, cli_available = true, root = "/repo", cache_entries = 3, stats = { hits = 4, lookups = 2, timeouts = 1 } },
      })), "\n")
      h.match("repo index: /repo %(3 cached symbols, 4 hits, 2 lookups, 1 timeouts%)", text)

      text = table.concat(commands.format_status(vim.tbl_extend("force", base, {
        repo_context = { enabled = true, cli_available = true, root = nil, cache_entries = 0, stats = {} },
      })), "\n")
      h.match("repo index: none for this buffer", text)
    end,
  },
}
