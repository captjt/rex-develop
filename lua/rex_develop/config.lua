-- The user's config, ~/.config/rex-develop/config.lua, with defaults filled
-- in and checked. It's a Lua file that returns a table, so hooks and
-- mappings can be plain functions. examples/config.lua shows every option.

local util = require("rex_develop.util")

local M = {}

local HOME = util.HOME
M.ROOT = nil -- the checkout of rex-develop, set by the entry point

-- The tool's name, where it labels things it doesn't own: Rex sessions,
-- status records, agent session names, and the footer.
M.APP = "rex-develop"

-- Each folder can be moved with an environment variable, so tests run
-- against their own.
local function dir(var, default)
  local v = os.getenv(var)
  return (v and v ~= "") and v or default
end

M.CONFIG_DIR = dir("REX_DEVELOP_CONFIG_DIR", HOME .. "/.config/rex-develop")
M.STATE_DIR = dir("REX_DEVELOP_STATE_DIR", HOME .. "/.local/state/rex-develop")
M.DATA_DIR = dir("REX_DEVELOP_DATA_DIR", HOME .. "/.local/share/rex-develop")
M.CACHE_DIR = dir("REX_DEVELOP_CACHE_DIR", HOME .. "/.cache/rex-develop")

-- Package caches the agents may write to, so builds stay warm across
-- tasks. Only the ones that exist are passed on.
local DEFAULT_CACHES = {
  "~/Library/Caches/go-build",
  "~/.cache/go-build",
  "~/go/pkg/mod",
  "~/.npm",
  "~/Library/pnpm/store",
  "~/.local/share/pnpm/store",
  "~/.cache/uv",
  "~/Library/Caches/ms-playwright",
  "~/.cache/ms-playwright",
  "~/.cargo/registry",
  "~/.cargo/git",
}

-- Guides point the agents at your own skills or instructions. A value is a
-- path to a file (such as a SKILL.md), a string of instructions, "bundled"
-- for the guide in guides/, or false for none. A repo's guides override
-- these slot by slot.
--   plan        how the builder plans (beyond the plan format)
--   build       how the builder builds
--   check       extra instructions for the checker
--   pr_style    how the PR's title and body read
--   plan_format the plan's sections (the plan block on the PR reads them)
local DEFAULT_GUIDES = {
  plan = false,
  build = false,
  check = false,
  pr_style = "bundled",
  plan_format = "bundled",
}

local BUNDLED = {
  pr_style = "guides/pr-style.md",
  plan_format = "guides/plan-format.md",
}

M.EFFORT_LEVELS = { low = true, medium = true, high = true, xhigh = true, max = true }

local AGENTS = { claude = true, codex = true }
local GATE_MODES = { ask = true, auto = true }
local PLAN_MODES = { full = true, summary = true }

local DEFAULTS = {
  session = M.APP,
  builder = "claude",
  checker = "codex",
  inbox = "auto",
  max_decisions = 3,
  max_tasks = 2,
  fix_loops = 2,
  poll_seconds = 180,
  branch_prefix = "agent/",
  caches = DEFAULT_CACHES,
  extra_caches = {},
  path = {},
  agents = {},
  hooks = {},
}

local loaded

function M.set_root(root)
  M.ROOT = root
end

function M.path()
  return M.CONFIG_DIR .. "/config.lua"
end

local function fail(msg)
  error("rex-develop config (" .. M.path() .. "): " .. msg, 0)
end

local function agent_spec(v, slot)
  if type(v) == "string" then
    v = { agent = v }
  end
  if type(v) ~= "table" or not AGENTS[v.agent] then
    fail(slot .. ' must be "claude" or "codex", or { agent = "claude", extra_args = {...}, effort = "high" }')
  end
  if v.effort ~= nil and v.effort ~= false and not M.EFFORT_LEVELS[v.effort] then
    fail(slot .. ".effort must be low, medium, high, xhigh, or max")
  end
  return { agent = v.agent, extra_args = v.extra_args or {}, effort = v.effort or nil }
end

local function gate(v, name)
  if not GATE_MODES[v] then
    fail(string.format('gates.%s must be "ask" or "auto"', name))
  end
  return v
end

local function normalize_linear(l)
  if l == nil or l == false then
    return nil
  end
  if type(l) ~= "table" then
    fail("trackers.linear must be a table")
  end
  local out = {
    label = l.label == nil and "agent" or l.label,
    cycle = l.cycle == nil and true or l.cycle,
    skip_label = l.skip_label == nil and "no-agent" or l.skip_label,
    teams = l.teams or {},
    projects = l.projects or {},
    repo = l.repo,
    endpoint = l.endpoint or "https://api.linear.app/graphql",
    key = l.key or { keychain = "rex-develop-linear", env = "LINEAR_API_KEY" },
  }
  if out.label == false and not out.cycle then
    fail("trackers.linear needs a label, cycle = true, or both, or nothing would start")
  end
  if type(out.teams) ~= "table" and type(out.teams) ~= "function" then
    fail("trackers.linear.teams maps a team key to a repo, such as { ENG = \"acme/api\" }")
  end
  return out
end

local function normalize_github(g)
  if g == nil or g == false then
    return nil
  end
  if type(g) ~= "table" then
    fail("trackers.github must be a table")
  end
  return { label = g.label or "agent" }
end

-- Load and check the config. Errors say what's wrong and where.
function M.load(force)
  if loaded and not force then
    return loaded
  end
  local path = M.path()
  if not util.exists(path) then
    error("no config at " .. path .. "; run `rex-develop setup`", 0)
  end
  local chunk, err = loadfile(path)
  if not chunk then
    fail(err)
  end
  local ok, raw = pcall(chunk)
  if not ok then
    fail(raw)
  end
  if type(raw) ~= "table" then
    fail("it must return a table")
  end

  local c = {}
  for k, v in pairs(DEFAULTS) do
    c[k] = v
  end
  for k, v in pairs(raw) do
    c[k] = v
  end

  if type(c.session) ~= "string" or not c.session:match("^[a-z0-9][a-z0-9.-]*$") or #c.session > 24 then
    fail("session must be lowercase letters, digits, dots and dashes, up to 24")
  end
  c.builder = agent_spec(c.builder, "builder")
  c.checker = agent_spec(c.checker, "checker")
  if c.inbox ~= "auto" and c.inbox ~= true and c.inbox ~= false then
    fail('inbox must be "auto", true, or false')
  end
  for _, k in ipairs({ "max_decisions", "max_tasks", "fix_loops", "poll_seconds" }) do
    if type(c[k]) ~= "number" or c[k] < 0 or c[k] ~= math.floor(c[k]) then
      fail(k .. " must be a whole number")
    end
  end
  if c.poll_seconds < 30 then
    fail("poll_seconds must be 30 or more")
  end

  -- Gates: how each approval goes. start depends on the trigger.
  local g = raw.gates or {}
  local start = g.start
  if type(start) == "string" then
    start = { label = start, cycle = start }
  end
  start = start or {}
  c.gates = {
    start = { label = gate(start.label or "auto", "start.label"), cycle = gate(start.cycle or "ask", "start.cycle") },
    plan = gate(g.plan or "ask", "plan"),
    preview = gate(g.preview or "ask", "preview"),
    open = gate(g.open or "ask", "open"),
  }

  local pr = raw.pr or {}
  c.pr = { draft = pr.draft == nil and true or pr.draft, reviewers = pr.reviewers or {} }

  -- Repos.
  if type(c.repos) ~= "table" or next(c.repos) == nil then
    fail('add at least one repo: repos = { ["owner/name"] = { checkout = "~/src/name" } }')
  end
  c.repo_list = {}
  local repos = {}
  for slug, r in pairs(c.repos) do
    local owner, name = util.split_slug(slug)
    if not owner then
      fail(string.format("repo %q must be owner/name", tostring(slug)))
    end
    if type(r) ~= "table" or type(r.checkout) ~= "string" then
      fail(string.format("repos[%q] needs checkout, the path to a clone of it", slug))
    end
    if r.plan ~= nil and r.plan ~= false and not PLAN_MODES[r.plan] then
      fail(string.format('repos[%q].plan must be "full", "summary", or false', slug))
    end
    local entry = {
      slug = slug, owner = owner, name = name,
      checkout = util.expand(r.checkout),
      base = r.base,
      notes = r.notes,
      plan = r.plan,
      guides = r.guides or {},
      builder = r.builder and agent_spec(r.builder, string.format("repos[%q].builder", slug)) or nil,
      checker = r.checker and agent_spec(r.checker, string.format("repos[%q].checker", slug)) or nil,
    }
    repos[slug] = entry
    c.repo_list[#c.repo_list + 1] = entry
  end
  table.sort(c.repo_list, function(a, b)
    return a.slug < b.slug
  end)
  c.repos = repos

  -- Trackers.
  local t = raw.trackers or {}
  c.trackers = { linear = normalize_linear(t.linear), github = normalize_github(t.github) }
  if not c.trackers.linear and not c.trackers.github then
    fail("add a tracker: trackers = { linear = { label = \"agent\", teams = { ENG = \"owner/name\" } } }")
  end
  if c.trackers.linear and type(c.trackers.linear.teams) == "table" then
    for team, repo in pairs(c.trackers.linear.teams) do
      local list = type(repo) == "table" and repo or { repo }
      for _, slug in ipairs(list) do
        if not repos[slug] then
          fail(string.format("trackers.linear.teams.%s names %s, which isn't in repos", team, tostring(slug)))
        end
      end
    end
  end

  -- Guides, slot by slot.
  local guides = {}
  for k, v in pairs(DEFAULT_GUIDES) do
    guides[k] = v
  end
  for k, v in pairs(raw.guides or {}) do
    if DEFAULT_GUIDES[k] == nil then
      fail("guides has no slot " .. tostring(k))
    end
    guides[k] = v
  end
  c.guides = guides

  -- Caches and PATH.
  local caches = {}
  for _, d in ipairs(c.caches) do
    caches[#caches + 1] = util.expand(d)
  end
  for _, d in ipairs(c.extra_caches) do
    caches[#caches + 1] = util.expand(d)
  end
  c.caches = caches
  util.set_extra_path(c.path)

  loaded = c
  return c
end

-- The agent spec for a task's role (builder or checker): the repo's own, or
-- the config's.
function M.agent_for(repo, role)
  local c = M.load()
  local r = c.repos[repo]
  return (r and r[role]) or c[role]
end

-- The text of a guide slot for a repo: the repo's value, else the config's.
-- nil when the slot is off.
function M.guide(repo, slot)
  local c = M.load()
  local r = c.repos[repo]
  local v = r and r.guides[slot]
  if v == nil then
    v = c.guides[slot]
  end
  if v == false or v == nil then
    return nil
  end
  if v == "bundled" then
    return util.read_file(M.ROOT .. "/" .. BUNDLED[slot])
  end
  if type(v) ~= "string" then
    fail("guides." .. slot .. " must be a path, a string, \"bundled\", or false")
  end
  local p = util.expand(v)
  if (p:sub(1, 1) == "/") and not p:find("\n") then
    local s = util.read_file(p)
    if not s then
      fail("guides." .. slot .. " names " .. p .. ", which can't be read")
    end
    return s
  end
  return v
end

-- The plan mode for a repo: "full", "summary", or false. Unset, a public
-- repo gets "summary" (the plan shouldn't quote a private tracker on a
-- public PR), and anything else "full".
function M.plan_mode(repo, is_public)
  local r = M.load().repos[repo]
  if r and r.plan ~= nil then
    return r.plan
  end
  return is_public and "summary" or "full"
end

return M
