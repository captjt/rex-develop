-- GitHub Issues, through gh, signed in as you. An open issue in a
-- configured repo, assigned to you, with the trigger label starts a task.
-- GitHub has no cycles, so only the label (or `rex-develop start`) does.

local util = require("rex_develop.util")
local config = require("rex_develop.config")

local M = { name = "github" }

local ISSUE_FIELDS = [[
number title url state updatedAt
repository { nameWithOwner }
labels(first: 50) { nodes { name } }
assignees(first: 20) { nodes { login } }
comments { totalCount }
]]

local function cfg()
  return config.load().trackers.github
end

local function has(list, name)
  for _, v in ipairs(list) do
    if tostring(v):lower() == tostring(name):lower() then
      return true
    end
  end
  return false
end

-- A branch name for an issue: the prefix, the number, and the title's
-- first words, as GitHub's own "create a branch" does.
function M.branch_name(prefix, number, title)
  local slug = tostring(title or ""):lower():gsub("[^a-z0-9]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  if #slug > 40 then
    slug = slug:sub(1, 40):gsub("-[^-]*$", "")
  end
  return string.format("%s%d%s", prefix or "", number, slug ~= "" and ("-" .. slug) or "")
end

-- One observation from an issue node. Pure: tests/github.lua feeds it
-- made-up responses.
function M.observe(node, login, c, prefix)
  local labels = {}
  for _, l in ipairs(util.list(node.labels and node.labels.nodes)) do
    labels[#labels + 1] = l.name
  end
  local assignees = {}
  for _, a in ipairs(util.list(node.assignees and node.assignees.nodes)) do
    assignees[#assignees + 1] = a.login
  end
  local slug = node.repository and node.repository.nameWithOwner
  local o = {
    tracker = "github",
    key = string.format("%s#%d", slug, node.number),
    number = node.number,
    title = node.title,
    url = node.url,
    priority = 0,
    updated_at = node.updatedAt,
    state_name = node.state == "OPEN" and "open" or "closed",
    labels = labels,
    repo = slug,
    comments = node.comments and node.comments.totalCount or 0,
    branch = M.branch_name(prefix, node.number, node.title),
  }
  o.mine = has(assignees, login)
  o.open_for_work = node.state == "OPEN"
  o.finished = node.state == "CLOSED"
  o.label_match = c.label and has(labels, c.label) or false
  o.skip = false
  o.cycle_active = false
  return o
end

-- The scan query: labeled open issues assigned to you in the configured
-- repos, and each tracked issue by number, whatever its state.
function M.scan_query(repos, tracked)
  local parts = { "query($q: String!) { viewer { login } search(query: $q, type: ISSUE, first: 100) { nodes { ... on Issue { " .. ISSUE_FIELDS:gsub("%s+", " ") .. "} } }" }
  for i, r in ipairs(repos) do
    local nums = tracked[r.slug] or {}
    if #nums > 0 then
      local issues = {}
      for _, n in ipairs(nums) do
        issues[#issues + 1] = string.format("i%d: issue(number: %d) { %s }", n, n, ISSUE_FIELDS:gsub("%s+", " "))
      end
      parts[#parts + 1] = string.format(' r%d: repository(owner: "%s", name: "%s") { %s }', i, r.owner, r.name, table.concat(issues, " "))
    end
  end
  parts[#parts + 1] = " }"
  return table.concat(parts)
end

function M.search_string(repos, label)
  local q = { "is:issue", "is:open", "assignee:@me", string.format('label:"%s"', label) }
  for _, r in ipairs(repos) do
    q[#q + 1] = "repo:" .. r.slug
  end
  return table.concat(q, " ")
end

function M.observations(data, repos, tracked, c, prefix)
  local login = data.viewer and data.viewer.login
  local out, seen = {}, {}
  local function add(node)
    if node and node.number and node.repository then
      local k = node.repository.nameWithOwner .. "#" .. node.number
      if not seen[k] then
        seen[k] = true
        out[#out + 1] = M.observe(node, login, c, prefix)
      end
    end
  end
  for _, node in ipairs(util.list(data.search and data.search.nodes)) do
    add(node)
  end
  for i, r in ipairs(repos) do
    local repo = data["r" .. i]
    for _, n in ipairs(tracked[r.slug] or {}) do
      add(repo and repo["i" .. n])
    end
  end
  return out, { login = login }
end

-- tracked: the task entries this tracker has, for their numbers.
function M.scan(tracked_tasks)
  local c = config.load()
  local tracked = {}
  for _, e in ipairs(tracked_tasks or {}) do
    if e.repo and e.number then
      tracked[e.repo] = tracked[e.repo] or {}
      tracked[e.repo][#tracked[e.repo] + 1] = e.number
    end
  end
  local q = M.scan_query(c.repo_list, tracked)
  local res = util.run({ "gh", "api", "graphql", "-f", "q=" .. M.search_string(c.repo_list, cfg().label), "-f", "query=" .. q })
  local j = util.decode(res.stdout) or {}
  if not j.data then
    error("gh returned no data: " .. util.trim(res.stdout):sub(1, 300), 0)
  end
  return M.observations(j.data, c.repo_list, tracked, cfg(), c.branch_prefix)
end

-- "owner/name#45" or "owner/name/issues/45" → slug, number.
function M.parse_key(key)
  local slug, n = tostring(key):match("^([^/#%s]+/[^/#%s]+)#(%d+)$")
  if not slug then
    slug, n = tostring(key):match("github%.com/([^/]+/[^/]+)/issues/(%d+)")
  end
  return slug, tonumber(n)
end

function M.lookup(key)
  local c = config.load()
  local slug, n = M.parse_key(key)
  if not slug then
    error("a GitHub issue looks like owner/name#45", 0)
  end
  local owner, name = util.split_slug(slug)
  local q = string.format('query { viewer { login } repository(owner: "%s", name: "%s") { issue(number: %d) { %s } } }',
    owner, name, n, ISSUE_FIELDS:gsub("%s+", " "))
  local res = util.run({ "gh", "api", "graphql", "-f", "query=" .. q })
  local j = util.decode(res.stdout) or {}
  local node = j.data and j.data.repository and j.data.repository.issue
  if not node then
    error("GitHub has no issue " .. key, 0)
  end
  return M.observe(node, j.data.viewer.login, cfg() or { label = "agent" }, c.branch_prefix)
end

function M.render(issue)
  local out = {
    string.format("# #%d: %s", issue.number, issue.title or ""),
    "",
    string.format("Opened by: %s · %s", issue.author and issue.author.login or "?", issue.url or ""),
    "",
    "## Description",
    "",
    (issue.body ~= nil and issue.body ~= "") and issue.body or "(none)",
    "",
    "## Comments",
  }
  local comments = util.list(issue.comments)
  if #comments == 0 then
    out[#out + 1] = ""
    out[#out + 1] = "(none)"
  end
  for _, cm in ipairs(comments) do
    out[#out + 1] = ""
    out[#out + 1] = string.format("### %s, %s", cm.author and cm.author.login or "someone", cm.createdAt or "")
    out[#out + 1] = ""
    out[#out + 1] = cm.body or ""
  end
  return table.concat(out, "\n") .. "\n"
end

function M.context(e, dir)
  local res = util.run({ "gh", "issue", "view", tostring(e.number), "--repo", e.repo,
    "--json", "number,title,body,url,labels,comments,author,assignees,milestone" })
  local issue = util.decode(res.stdout) or {}
  util.mkdirp(dir)
  util.write_file(dir .. "/issue.json", util.json(issue) .. "\n")
  util.write_file(dir .. "/issue.md", M.render(issue))
  return { comments = #util.list(issue.comments) }
end

function M.branch(e)
  return e.branch or M.branch_name(config.load().branch_prefix, e.number, e.title)
end

function M.closes(e)
  return string.format("Closes #%d", e.number)
end

return M
