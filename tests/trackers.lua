-- The tracker adapters' mappings, on made-up responses: luajit tests/trackers.lua

local ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/tests/[^/]+$") or "."
package.path = ROOT .. "/lua/?.lua;" .. package.path
local t = dofile(ROOT .. "/tests/t.lua")
local util = require("rex_develop.util")
local linear = require("rex_develop.trackers.linear")
local github = require("rex_develop.trackers.github")

---------------------------------------------------------------------------
-- Linear

local cfg = {
  label = "agent", cycle = true, skip_label = "no-agent",
  teams = { ENG = "acme/api", WEB = { "acme/web", "acme/dashboard" } },
  projects = { ["Webhooks v2"] = "acme/webhooks" },
}

local data = util.decode(util.read_file(ROOT .. "/tests/fixtures/linear-scan.json")).data
local obs = linear.observations(data, cfg)
t.eq("each issue once, matching and tracked together", #obs, 4)
local by = {}
for _, o in ipairs(obs) do
  by[o.key] = o
end

local o = by["ENG-142"]
t.eq("the key", o.key, "ENG-142")
t.eq("Linear's own branch name", o.branch, "sam/eng-142-retry-failed-webhook-deliveries")
t.ok("mine", o.mine)
t.ok("open for work in Todo", o.open_for_work)
t.ok("labels match whatever their case", o.label_match)
t.ok("in the active cycle", o.cycle_active)
t.eq("its team's repo", o.repo, "acme/api")
t.eq("comments counted", o.comments, 2)
t.eq("its Linear id, for tracking", o.issue_id, "iss-142")

t.eq("a project's repo wins over the team's", by["ENG-150"].repo, "acme/webhooks")
t.ok("an issue in the cycle with no label is a cycle issue", by["ENG-150"].cycle_active and not by["ENG-150"].label_match)
t.eq("a team with two repos picks by a label that names one", by["WEB-77"].repo, "acme/dashboard")

local gone = by["ENG-120"]
t.ok("a canceled issue is finished", gone.finished)
t.ok("and not mine any more", not gone.mine)

-- No matching label: the candidates.
local repo, choices = linear.repo_for({ team = "WEB", labels = {} }, cfg)
t.eq("no label picks no repo", repo, nil)
t.eq("so the team's repos are the choices", choices, { "acme/web", "acme/dashboard" })
t.eq("a function maps it", linear.repo_for({ team = "X" }, { teams = function()
  return "acme/x"
end }), "acme/x")
t.eq("an unmapped team falls back to the default", linear.repo_for({ team = "OPS", labels = {} }, { teams = {}, projects = {}, repo = "acme/ops" }), "acme/ops")

-- The filter and the query.
local f = linear.filter(cfg)
t.eq("only my issues", f.assignee, { isMe = { eq = true } })
t.eq("only unstarted ones", f.state, { type = { eq = "unstarted" } })
t.eq("labeled or in the cycle", #f["or"], 2)
t.eq("only the mapped teams", f.team, { key = { ["in"] = { "ENG", "WEB" } } })
local only_label = linear.filter({ label = "agent", cycle = false, teams = {} })
t.eq("without the cycle, just the label", only_label.labels, { some = { name = { eqIgnoreCase = "agent" } } })
t.eq("and no or", only_label["or"], nil)
t.eq("with no tracked issues, the query asks for none", linear.scan_query({}):find("tracked:", 1, true), nil)
t.has("with some, it does", linear.scan_query({ "iss-1" }), "tracked: issues(filter: { id: { in: $ids } }")
t.has("the fields go in a fragment", linear.scan_query({}), "fragment F on Issue { id identifier title url branchName")

t.eq("the PR closes the issue", linear.closes({ key = "ENG-142" }), "Closes ENG-142")

-- issue.md
local md = linear.render({
  identifier = "ENG-142", title = "Retry failed webhook deliveries", description = "Deliveries that fail are lost.",
  state = { name = "Todo" }, priorityLabel = "High", team = { key = "ENG" },
  labels = { nodes = { { name = "agent" } } },
  comments = { nodes = {
    { body = "Second", createdAt = "2026-11-02T00:00:00Z", user = { name = "Lee" } },
    { body = "First", createdAt = "2026-11-01T00:00:00Z", user = { name = "Ana" } },
  } },
  children = { nodes = { { identifier = "ENG-143", title = "Backoff", state = { name = "Todo" } } } },
})
t.has("the title", md, "# ENG-142: Retry failed webhook deliveries")
t.has("the details", md, "State: Todo · Priority: High · Team: ENG · Labels: agent")
t.has("the description", md, "Deliveries that fail are lost.")
t.has("sub-issues", md, "- ENG-143 Backoff (Todo)")
t.ok("comments oldest first", md:find("First", 1, true) < md:find("Second", 1, true))

---------------------------------------------------------------------------
-- GitHub

local gdata = {
  viewer = { login = "sam" },
  search = { nodes = {
    { number = 45, title = "Add a --json flag to export", url = "https://github.com/acme/api/issues/45", state = "OPEN",
      repository = { nameWithOwner = "acme/api" }, labels = { nodes = { { name = "agent" } } },
      assignees = { nodes = { { login = "sam" } } }, comments = { totalCount = 1 } },
  } },
  r1 = {
    i12 = { number = 12, title = "Old one", url = "u", state = "CLOSED", repository = { nameWithOwner = "acme/api" },
      labels = { nodes = {} }, assignees = { nodes = {} }, comments = { totalCount = 0 } },
  },
}
local repos = { { slug = "acme/api", owner = "acme", name = "api" } }
local gobs = github.observations(gdata, repos, { ["acme/api"] = { 12 } }, { label = "agent" }, "agent/")
t.eq("search and tracked", #gobs, 2)
t.eq("the key is the repo and number", gobs[1].key, "acme/api#45")
t.eq("the branch", gobs[1].branch, "agent/45-add-a-json-flag-to-export")
t.ok("mine, labeled, open", gobs[1].mine and gobs[1].label_match and gobs[1].open_for_work)
t.ok("never a cycle", gobs[1].cycle_active == false)
t.ok("a closed tracked issue is finished", gobs[2].finished)
t.has("the search", github.search_string(repos, "agent"), 'is:issue is:open assignee:@me label:"agent" repo:acme/api')
t.has("tracked issues by number", github.scan_query(repos, { ["acme/api"] = { 12 } }), 'r1: repository(owner: "acme", name: "api") { i12: issue(number: 12)')
t.eq("a key parses", { github.parse_key("acme/api#45") }, { "acme/api", 45 })
t.eq("so does a URL", { github.parse_key("https://github.com/acme/api/issues/45") }, { "acme/api", 45 })
t.eq("a long title is cut at a word", github.branch_name("agent/", 7, "Make the export endpoint stream rows instead of buffering the whole result"),
  "agent/7-make-the-export-endpoint-stream-rows")
t.eq("the PR closes the issue", github.closes({ number = 45 }), "Closes #45")

t.done("trackers")
