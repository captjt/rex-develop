-- The agents: Claude Code and Codex, as a task's builder or checker. This
-- builds their command lines and the environment they run in, and reads
-- back the model each ran, for the PR's footer.
--
-- The environment is the wall between the agents and anything outside the
-- worktree. They commit, and never push: gh is signed out, there's no
-- Linear key, no SSH agent, git's credential helpers are cleared, and every
-- push URL is rewritten to one that can't work. Only the watcher pushes,
-- after you approve.

local util = require("rex_develop.util")
local config = require("rex_develop.config")

local M = {}

local HOME = util.HOME
local NEVER = "rex-develop-agents-never-push:///"

local function uuid()
  return util.trim(util.run({ "uuidgen" }).stdout):lower()
end

function M.program(name)
  local spec = config.load().agents[name] or {}
  return util.expand(spec.program or name)
end

local function args_for(name, defaults)
  local spec = config.load().agents[name] or {}
  local out = {}
  util.append(out, spec.args or defaults)
  util.append(out, spec.extra_args)
  return out
end

local function with_effort(name, args, level)
  if not level then
    return args
  end
  if name == "claude" then
    util.append(args, { "--effort", level })
  else
    util.append(args, { "-c", 'model_reasoning_effort="' .. level .. '"' })
  end
  return args
end

-- The excludes file the agents' git reads: your own global one, plus .tmp/,
-- where rex-develop's files for the task live, so no commit picks them up.
function M.excludes_file()
  local path = config.CACHE_DIR .. "/agent-gitignore"
  util.mkdirp(config.CACHE_DIR)
  local mine = util.trim(util.run({ "git", "config", "--global", "core.excludesFile" }, { check = false }).stdout)
  local src = mine ~= "" and util.expand(mine) or (HOME .. "/.config/git/ignore")
  local text = util.read_file(src) or ""
  util.write_file(path, text .. "\n# rex-develop: the task's own files\n.tmp/\n")
  return path
end

-- env(1) arguments for an agent in worktree wt.
function M.env_args(wt)
  util.mkdirp(wt .. "/.tmp/gh-empty")
  local cfg = {
    { "remote.origin.pushurl", NEVER },
    { "credential.helper", "" },
    { "url." .. NEVER .. ".pushInsteadOf", "https://" },
    { "url." .. NEVER .. ".pushInsteadOf", "git@" },
    { "url." .. NEVER .. ".pushInsteadOf", "ssh://" },
    { "core.excludesFile", M.excludes_file() },
  }
  local args = {
    "-u", "GH_TOKEN", "-u", "GITHUB_TOKEN", "-u", "LINEAR_API_KEY", "-u", "SSH_AUTH_SOCK",
    "GH_CONFIG_DIR=" .. wt .. "/.tmp/gh-empty",
    "GIT_TERMINAL_PROMPT=0",
    "GIT_SSH_COMMAND=false",
    "GIT_CONFIG_COUNT=" .. #cfg,
  }
  for i, kv in ipairs(cfg) do
    args[#args + 1] = string.format("GIT_CONFIG_KEY_%d=%s", i - 1, kv[1])
    args[#args + 1] = string.format("GIT_CONFIG_VALUE_%d=%s", i - 1, kv[2])
  end
  return args
end

-- What the agents may write outside the worktree: the clone's .git, where
-- commits land, and the package caches.
function M.writable_dirs(checkout)
  local out = {}
  local dirs = { checkout .. "/.git", config.CACHE_DIR }
  util.append(dirs, config.load().caches)
  for _, d in ipairs(dirs) do
    if util.exists(d) then
      out[#out + 1] = d
    end
  end
  return out
end

local function add_dirs(argv, flag, dirs)
  for _, d in ipairs(dirs) do
    util.append(argv, { flag, d })
  end
end

-- Claude Code never pushes or calls out, whatever its permission mode:
-- deny rules hold in every mode.
local CLAUDE_DENY = { "Bash(git push:*)", "Bash(gh:*)", "Bash(rex-inbox:*)", "Bash(curl:*api.linear.app*)" }

-- The command for a role ("builder" or "checker") in task e. spec is the
-- config's { agent, extra_args, effort }. Sets the session id on e for
-- Claude Code; Codex's is found after it starts.
function M.command(e, role, spec, wt, dirs)
  local name = spec.agent
  local session_field = role .. "_session"
  if name == "claude" then
    local argv = { M.program("claude") }
    if e[session_field] then
      util.append(argv, { "--resume", e[session_field] })
    else
      e[session_field] = uuid()
      util.append(argv, { "--session-id", e[session_field] })
    end
    local args = args_for("claude", { "--permission-mode", "auto" })
    util.append(args, spec.extra_args)
    util.append(argv, with_effort("claude", args, spec.effort))
    add_dirs(argv, "--add-dir", dirs)
    argv[#argv + 1] = "--disallowedTools"
    util.append(argv, CLAUDE_DENY)
    return util.append(argv, { "-n", string.format("%s %s %s", config.APP, e.key, role) })
  end
  local argv = { M.program("codex") }
  if e[session_field] then
    util.append(argv, { "resume", e[session_field] })
  end
  local args = args_for("codex", {
    "--approve-for-me", "--no-alt-screen", "--disable", "apps",
    "-c", 'plugins."github@openai-curated".enabled=false',
    -- Builds fetch dependencies. There's nothing to reach GitHub with.
    "-c", "sandbox_workspace_write.network_access=true",
  })
  util.append(args, spec.extra_args)
  util.append(argv, with_effort("codex", args, spec.effort))
  add_dirs(argv, "--add-dir", dirs)
  return util.append(argv, { "-C", wt })
end

---------------------------------------------------------------------------
-- Sessions and model names, for the footer.

local function claude_transcript(cwd, session)
  return HOME .. "/.claude/projects/" .. (cwd:gsub("[^%w]", "-")) .. "/" .. session .. ".jsonl"
end

-- "claude-opus-5-5" → "Opus 5.5".
function M.claude_model_name(id)
  local family, rest = (id or ""):match("^claude%-(%a+)%-(.+)$")
  if not family then
    return id ~= "" and id or nil
  end
  local version = {}
  for part in rest:gmatch("[^-]+") do
    if not part:match("^%d%d?$") then
      break
    end
    version[#version + 1] = part
  end
  local name = family:sub(1, 1):upper() .. family:sub(2)
  if #version > 0 then
    name = name .. " " .. table.concat(version, ".")
  end
  return name
end

function M.claude_name(cwd, session)
  local res = util.run({ "/bin/sh", "-c",
    [[grep -o '"model":"claude-[^"]*"' "$1" 2>/dev/null | tail -1 | cut -d'"' -f4]],
    "sh", claude_transcript(cwd, session or "none") }, { check = false })
  local model = M.claude_model_name(util.trim(res.stdout))
  return model and "Claude Code (" .. model .. ")" or "Claude Code"
end

local function codex_db()
  local res = util.run({ "/bin/sh", "-c", [[ls -t "$1"/state_*.sqlite 2>/dev/null | head -1]], "sh", HOME .. "/.codex" }, { check = false })
  local path = util.trim(res.stdout)
  return path ~= "" and path or nil
end

local function sql_quote(s)
  return "'" .. (s or ""):gsub("'", "''") .. "'"
end

local function codex_query(db, sql)
  local res = util.run({ "sqlite3", "-readonly", db, sql }, { check = false })
  if not res.ok then
    res = util.run({ "sqlite3", "file:" .. db .. "?immutable=1", sql }, { check = false })
  end
  return res.ok and util.trim(res.stdout) or ""
end

-- The newest top-level Codex thread in cwd started at or after since.
function M.codex_thread(cwd, since)
  local db = codex_db()
  if not db then
    return nil
  end
  local sql = "select id from threads where cwd = " .. sql_quote(cwd)
    .. (since and (" and created_at >= " .. math.floor(since)) or "")
    .. " and archived = 0 and source not like '{%' order by created_at desc limit 1"
  local id = codex_query(db, sql)
  return id ~= "" and id or nil
end

function M.codex_name(thread)
  local db = codex_db()
  local model = db and thread and codex_query(db, "select model from threads where id = " .. sql_quote(thread)) or ""
  if model == "" then
    return "Codex"
  end
  local models = util.decode(util.read_file(HOME .. "/.codex/models_cache.json"))
  for _, m in ipairs(models and models.models or {}) do
    if m.slug == model and m.display_name then
      return "Codex (" .. m.display_name .. ")"
    end
  end
  return "Codex (" .. model .. ")"
end

-- After an agent starts: its session id (Codex's, found by cwd).
function M.session_after_start(e, role, spec, wt, since)
  if spec.agent == "claude" then
    return e[role .. "_session"]
  end
  for _ = 1, 10 do
    local id = e[role .. "_session"] or M.codex_thread(wt, since)
    if id then
      return id
    end
    util.sleep(2)
  end
end

-- "Claude Code (Opus 5.5)": the agent and model a role ran.
function M.name(e, role)
  local agent = e[role .. "_agent"]
  local session = e[role .. "_session"]
  if agent == "claude" then
    return M.claude_name(e.worktree, session)
  elseif agent == "codex" then
    return M.codex_name(session)
  end
  return agent or "an agent"
end

return M
