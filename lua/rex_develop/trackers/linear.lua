-- Linear, through its GraphQL API with a personal API key. It only reads:
-- the issues that qualify, the ones rex-develop already tracks, and each
-- task's context. Linear's own GitHub integration links the PR (from the
-- branch name and the "Closes ENG-142" in its body) and moves the issue.
--
-- The key comes from the Keychain (service rex-develop-linear, which
-- `rex-develop setup-linear` stores), from LINEAR_API_KEY, or from a
-- command, as trackers.linear.key says. It only needs read access.

local util = require("rex_develop.util")
local config = require("rex_develop.config")

local M = { name = "linear" }

local FIELDS = [[
id identifier title url branchName priority updatedAt
state { name type }
assignee { id }
labels(first: 50) { nodes { name } }
cycle { id number isActive }
team { key }
project { name }
comments(first: 100) { nodes { id } }
]]

local function cfg()
  return config.load().trackers.linear
end

-- The API key, from the first source in trackers.linear.key that has one.
function M.api_key(spec)
  spec = spec or cfg().key
  if type(spec) == "string" then
    return spec
  end
  if spec.command then
    local res = util.run({ "/bin/sh", "-c", spec.command }, { check = false })
    local k = util.trim(res.stdout)
    if res.ok and k ~= "" then
      return k
    end
  end
  if spec.keychain then
    local res = util.run({ "security", "find-generic-password", "-s", spec.keychain, "-w" }, { check = false })
    local k = util.trim(res.stdout)
    if res.ok and k ~= "" then
      return k
    end
  end
  if spec.env then
    local k = os.getenv(spec.env)
    if k and k ~= "" then
      return k
    end
  end
  error("no Linear API key: run `rex-develop setup-linear`, or set LINEAR_API_KEY", 0)
end

-- One GraphQL request. The key goes in a header file, never on the
-- command line, where other processes could read it.
function M.graphql(query, variables)
  local c = cfg()
  util.mkdirp(config.CACHE_DIR)
  local headers = config.CACHE_DIR .. "/linear-headers"
  local f = assert(io.open(headers, "w"))
  f:write("Authorization: " .. M.api_key(c.key) .. "\n")
  f:write("Content-Type: application/json\n")
  f:close()
  util.run({ "chmod", "600", headers }, { check = false })
  local body = util.json({ query = query, variables = variables or {} })
  local res = util.run({ "curl", "-sS", "--max-time", "30", "-X", "POST", c.endpoint, "-H", "@" .. headers, "--data-binary", "@-" },
    { input = body, check = false })
  os.remove(headers)
  if not res.ok then
    error("Linear didn't answer: " .. util.trim(res.stderr):sub(1, 300), 0)
  end
  local j = util.decode(res.stdout)
  if not j then
    error("Linear's answer isn't JSON: " .. util.trim(res.stdout):sub(1, 300), 0)
  end
  if type(j.errors) == "table" and j.errors[1] then
    local msgs = {}
    for _, e in ipairs(j.errors) do
      msgs[#msgs + 1] = tostring(e.message)
    end
    error("Linear: " .. table.concat(msgs, "; "):sub(1, 400), 0)
  end
  return j.data or {}
end

-- The filter for the issues that could start a task: assigned to you, in an
-- unstarted state, labeled or in the active cycle, in a mapped team.
function M.filter(c)
  local either = {}
  if c.label then
    either[#either + 1] = { labels = { some = { name = { eqIgnoreCase = c.label } } } }
  end
  if c.cycle then
    either[#either + 1] = { cycle = { isActive = { eq = true } } }
  end
  local f = {
    assignee = { isMe = { eq = true } },
    state = { type = { eq = "unstarted" } },
  }
  if #either == 1 then
    for k, v in pairs(either[1]) do
      f[k] = v
    end
  else
    f["or"] = either
  end
  if type(c.teams) == "table" and next(c.teams) and not c.repo then
    local keys = {}
    for k in pairs(c.teams) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    f.team = { key = { ["in"] = keys } }
  end
  return f
end

-- The query for a scan, with the tracked issues by id when there are any.
function M.scan_query(tracked_ids)
  local parts = { "query RexDevelopScan($filter: IssueFilter!" }
  if #tracked_ids > 0 then
    parts[#parts + 1] = ", $ids: [ID!]"
  end
  parts[#parts + 1] = ") { viewer { id name } matching: issues(filter: $filter, first: 100) { nodes { ...F } }"
  if #tracked_ids > 0 then
    parts[#parts + 1] = " tracked: issues(filter: { id: { in: $ids } }, first: 100) { nodes { ...F } }"
  end
  parts[#parts + 1] = " } fragment F on Issue { " .. FIELDS:gsub("%s+", " ") .. "}"
  return table.concat(parts)
end

local function has(list, name)
  if not name then
    return false
  end
  for _, v in ipairs(list) do
    if tostring(v):lower() == tostring(name):lower() then
      return true
    end
  end
  return false
end

-- The repo an issue builds in: a project mapping, the team's, or the
-- default. A team with several repos picks the one whose name is a label
-- on the issue. Returns a slug, or nil and the candidates.
function M.repo_for(o, c)
  if type(c.teams) == "function" then
    local r = c.teams(o)
    if type(r) == "string" then
      return r
    end
    if type(r) == "table" then
      return nil, r
    end
    return nil, nil
  end
  if o.project and c.projects[o.project] then
    return c.projects[o.project]
  end
  local t = c.teams[o.team]
  if type(t) == "string" then
    return t
  end
  if type(t) == "table" then
    local hits = {}
    for _, slug in ipairs(t) do
      local _, name = util.split_slug(slug)
      if has(o.labels, name) then
        hits[#hits + 1] = slug
      end
    end
    if #hits == 1 then
      return hits[1]
    end
    return nil, t
  end
  return c.repo, nil
end

-- One observation from an issue node. Pure: tests/linear.lua feeds it
-- made-up responses.
function M.observe(node, viewer, c)
  local labels = {}
  for _, l in ipairs(util.list(node.labels and node.labels.nodes)) do
    labels[#labels + 1] = l.name
  end
  local st = node.state or {}
  local o = {
    tracker = "linear",
    key = node.identifier,
    issue_id = node.id,
    title = node.title,
    url = node.url,
    branch = node.branchName,
    priority = node.priority or 0,
    updated_at = node.updatedAt,
    state_name = st.name,
    state_type = st.type,
    labels = labels,
    team = node.team and node.team.key or nil,
    project = node.project and node.project.name or nil,
    cycle_id = node.cycle and node.cycle.id or nil,
    comments = #util.list(node.comments and node.comments.nodes),
  }
  o.mine = node.assignee ~= nil and viewer ~= nil and node.assignee.id == viewer.id
  o.open_for_work = st.type == "unstarted"
  o.finished = st.type == "completed" or st.type == "canceled"
  o.label_match = c.label and has(labels, c.label) or false
  o.skip = c.skip_label and has(labels, c.skip_label) or false
  o.cycle_active = (c.cycle and node.cycle and node.cycle.isActive) and true or false
  o.repo, o.repo_choices = M.repo_for(o, c)
  return o
end

-- Observations for the issues that qualify now, and for the tracked ones
-- (by Linear id) whatever their state.
function M.scan(tracked_ids)
  local c = cfg()
  local data = M.graphql(M.scan_query(tracked_ids), { filter = M.filter(c), ids = #tracked_ids > 0 and tracked_ids or nil })
  return M.observations(data, c)
end

function M.observations(data, c)
  local viewer = data.viewer
  local seen, out = {}, {}
  for _, group in ipairs({ "matching", "tracked" }) do
    for _, node in ipairs(util.list(data[group] and data[group].nodes)) do
      if not seen[node.id] then
        seen[node.id] = true
        out[#out + 1] = M.observe(node, viewer, c)
      end
    end
  end
  return out, viewer
end

-- One issue by its key, for `rex-develop start ENG-142`.
function M.lookup(key)
  local c = cfg()
  local q = "query($id: String!) { viewer { id name } issue(id: $id) { " .. FIELDS:gsub("%s+", " ") .. " } }"
  local data = M.graphql(q, { id = key })
  if not data.issue then
    error("Linear has no issue " .. key, 0)
  end
  return M.observe(data.issue, data.viewer, c)
end

local CONTEXT_QUERY = [[
query($id: String!) { issue(id: $id) {
  identifier title url description priority priorityLabel branchName
  state { name } team { key name } project { name } cycle { number name }
  labels(first: 50) { nodes { name } }
  creator { name } assignee { name }
  comments(first: 100) { nodes { body createdAt user { name } } }
  parent { identifier title description }
  children(first: 50) { nodes { identifier title description state { name } } }
  relations(first: 50) { nodes { type relatedIssue { identifier title state { name } } } }
  attachments(first: 50) { nodes { title url } }
} }]]

-- issue.md: the issue as the agents read it.
function M.render(issue)
  local out = {}
  local function add(s)
    out[#out + 1] = s or ""
  end
  add(string.format("# %s: %s", issue.identifier, issue.title or ""))
  add("")
  local meta = {}
  if issue.state then
    meta[#meta + 1] = "State: " .. tostring(issue.state.name)
  end
  if issue.priorityLabel then
    meta[#meta + 1] = "Priority: " .. tostring(issue.priorityLabel)
  end
  if issue.team then
    meta[#meta + 1] = "Team: " .. tostring(issue.team.key)
  end
  if issue.project then
    meta[#meta + 1] = "Project: " .. tostring(issue.project.name)
  end
  if issue.cycle then
    meta[#meta + 1] = "Cycle: " .. tostring(issue.cycle.name or issue.cycle.number)
  end
  local labels = {}
  for _, l in ipairs(util.list(issue.labels and issue.labels.nodes)) do
    labels[#labels + 1] = l.name
  end
  if #labels > 0 then
    meta[#meta + 1] = "Labels: " .. table.concat(labels, ", ")
  end
  if issue.creator then
    meta[#meta + 1] = "Opened by: " .. tostring(issue.creator.name)
  end
  add(table.concat(meta, " · "))
  add("")
  add("## Description")
  add("")
  add(issue.description ~= nil and issue.description ~= "" and issue.description or "(none)")
  if issue.parent then
    add("")
    add("## Parent: " .. issue.parent.identifier .. " " .. (issue.parent.title or ""))
    add("")
    add(issue.parent.description or "")
  end
  local kids = util.list(issue.children and issue.children.nodes)
  if #kids > 0 then
    add("")
    add("## Sub-issues")
    for _, k in ipairs(kids) do
      add(string.format("- %s %s (%s)", k.identifier, k.title or "", k.state and k.state.name or "?"))
    end
  end
  local rel = util.list(issue.relations and issue.relations.nodes)
  if #rel > 0 then
    add("")
    add("## Related")
    for _, r in ipairs(rel) do
      local ri = r.relatedIssue or {}
      add(string.format("- %s: %s %s (%s)", r.type or "related", ri.identifier or "?", ri.title or "", ri.state and ri.state.name or "?"))
    end
  end
  local att = util.list(issue.attachments and issue.attachments.nodes)
  if #att > 0 then
    add("")
    add("## Links")
    for _, a in ipairs(att) do
      add(string.format("- [%s](%s)", a.title or a.url, a.url or ""))
    end
  end
  local comments = util.list(issue.comments and issue.comments.nodes)
  table.sort(comments, function(a, b)
    return (a.createdAt or "") < (b.createdAt or "")
  end)
  add("")
  add("## Comments")
  if #comments == 0 then
    add("")
    add("(none)")
  end
  for _, cm in ipairs(comments) do
    add("")
    add(string.format("### %s, %s", cm.user and cm.user.name or "someone", cm.createdAt or ""))
    add("")
    add(cm.body or "")
  end
  return table.concat(out, "\n") .. "\n"
end

-- Write the task's context into dir: issue.json and issue.md. Returns the
-- number of comments, which the task marks as seen.
function M.context(e, dir)
  local data = M.graphql(CONTEXT_QUERY, { id = e.key })
  local issue = data.issue
  if not issue then
    error("Linear has no issue " .. tostring(e.key), 0)
  end
  util.mkdirp(dir)
  util.write_file(dir .. "/issue.json", util.json(issue) .. "\n")
  util.write_file(dir .. "/issue.md", M.render(issue))
  return { comments = #util.list(issue.comments and issue.comments.nodes), branch = issue.branchName }
end

-- The branch the task builds on: Linear's own name for the issue, which is
-- what links the PR to it.
function M.branch(e)
  return e.branch or ("agent/" .. tostring(e.key):lower())
end

-- What the PR body says to link and close the issue.
function M.closes(e)
  return "Closes " .. tostring(e.key)
end

return M
