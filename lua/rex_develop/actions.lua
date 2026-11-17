-- The actions: what you, apps, and other tools can ask rex-develop to do.
-- bin/rex-develop runs them under LuaJIT (scripts/cli.lua); init.lua also
-- registers them as Rex actions (`rex do develop_answer …`), for key
-- bindings and for tools that act on the watcher's status records.
--
-- No action changes a task itself. An answer is queued for the watcher,
-- which applies it on its next step, so nothing races the watcher.

local util = require("rex_develop.util")
local config = require("rex_develop.config")
local ledger = require("rex_develop.ledger")
local status = require("rex_develop.status")

local M = { list = {}, by_name = {} }

local function action(name, title, args, run, opts)
  local a = { name = name, title = title, args = args, run = run, rex = not (opts and opts.rex == false) }
  M.list[#M.list + 1] = a
  M.by_name[name] = a
end

-- The task an action names: task= (ENG-142, acme/api#45, or a task id), or
-- item= (a status record's id, task/<task>/<what>).
local function target(a)
  if a.item and a.item ~= "" then
    local seg, what = tostring(a.item):match("^task/([^/]+)/([^/]+)$")
    if not seg then
      error(string.format("%s isn't a rex-develop item; items look like task/<task>/<what>", a.item), 0)
    end
    for _, e in ipairs(ledger.list()) do
      if status.segment(e.id) == seg then
        return e, what
      end
    end
    error(a.item .. " names no task", 0)
  end
  local e = ledger.find(a.task)
  if not e then
    error(string.format("no task %s; `rex-develop status` lists them", tostring(a.task)), 0)
  end
  return e, a.what
end

action("develop_status", "status", nil, function()
  return require("rex_develop.watcher").status()
end)

action("develop_doctor", "check the setup", nil, function()
  return require("rex_develop.watcher").doctor()
end, { rex = false })

action("develop_up", "start or repair the watcher", nil, function()
  return require("rex_develop.watcher").up()
end, { rex = false })

action("develop_down", "stop the watcher", nil, function()
  return require("rex_develop.watcher").down()
end, { rex = false })

action("develop_pause", "pause starting new tasks", nil, function()
  return ledger.set_paused(true)
end)

action("develop_resume", "resume starting new tasks", nil, function()
  return ledger.set_paused(false)
end)

action("develop_check", "check the trackers now", nil, function()
  util.mkdirp(config.STATE_DIR)
  util.write_file(ledger.check_now_path(), "")
  return { requested = true }
end)

action("develop_scan", "check the trackers (a dry run unless save=true)", { save = "boolean?" }, function(a)
  local evs = require("rex_develop.watcher").scan({ dry = not a.save })
  return { dry_run = not a.save, events = evs }
end, { rex = false })

-- What waits on you: every task's asks.
action("develop_asks", "what waits on you", nil, function()
  local out = {}
  for _, e in ipairs(ledger.list()) do
    for what, ask in pairs(type(e.asks) == "table" and e.asks or {}) do
      out[#out + 1] = {
        task = e.key, label = ledger.label(e), what = what, kind = ask.kind, subject = ask.subject,
        body = ask.body, options = ask.options, version = ask.version, message_id = ask.message_id,
        asked_at = ask.asked_at, item = status.item_id(e.id, what),
      }
    end
  end
  table.sort(out, function(x, y)
    return (x.asked_at or "") < (y.asked_at or "")
  end)
  return out
end)

-- Answer an ask: task= and what= (plan, open, D1, …), or item=. choice is
-- an option's label or number; text is anything more, or the whole answer.
action("develop_answer", "answer what waits on you", {
  task = "string?", what = "string?", item = "string?", choice = "string?", text = "string?", version = "integer?",
}, function(a)
  local e, what = target(a)
  if not what or what == "" then
    local open = {}
    for w in pairs(type(e.asks) == "table" and e.asks or {}) do
      open[#open + 1] = w
    end
    table.sort(open)
    if #open == 1 then
      what = open[1]
    else
      error(string.format("%s has %s waiting; say which with what=", ledger.label(e), #open == 0 and "nothing" or table.concat(open, ", ")), 0)
    end
  end
  local ask = type(e.asks) == "table" and e.asks[what] or nil
  if not ask then
    error(string.format("%s has no %s waiting on you", ledger.label(e), what), 0)
  end
  if (not a.choice or a.choice == "") and (not a.text or a.text == "") then
    error("give choice= (one of: " .. table.concat(ask.options or {}, ", ") .. "), text=, or both", 0)
  end
  -- A number picks by position, as in the message.
  local choice = a.choice
  local n = tonumber(choice)
  if n and ask.options and ask.options[n] then
    choice = ask.options[n]
  end
  ledger.queue_answer({ task = e.id, what = what, version = a.version or ask.version, choice = choice, text = a.text, via = "cli" })
  return { queued = true, task = e.key, what = what, choice = choice, note = "the watcher applies it within a few seconds" }
end)

-- Take an issue by hand, whether or not it qualifies.
action("develop_start", "start a task for an issue", { issue = "string" }, function(a)
  local trackers = require("rex_develop.trackers")
  local tracker = trackers.for_key(a.issue)
  if not config.load().trackers[tracker.name] then
    error(string.format("trackers.%s isn't in the config", tracker.name), 0)
  end
  local o = tracker.lookup(a.issue)
  local id = ledger.task_id(o.tracker, o.key)
  local e = ledger.load(id)
  if e and not ledger.TERMINAL[e.state] and e.state ~= "skipped" and e.state ~= "deferred" and e.state ~= "offered" then
    error(string.format("%s is already %s", o.key, e.state), 0)
  end
  e = {
    id = id, tracker = o.tracker, key = o.key, issue_id = o.issue_id, number = o.number,
    title = o.title, url = o.url, priority = o.priority, labels = o.labels, branch = o.branch,
    repo = o.repo, repo_choices = (not o.repo) and o.repo_choices or nil,
    state = "queued", trigger = "manual", round = 0, created_at = (e and e.created_at) or util.now(), queued_at = util.now(),
    comments_seen = o.comments,
  }
  if not e.repo and not e.repo_choices then
    e.repo_choices = {}
    for _, r in ipairs(config.load().repo_list) do
      e.repo_choices[#e.repo_choices + 1] = r.slug
    end
  end
  ledger.save(e)
  ledger.append_event({ kind = "queued", task = o.key, note = "by hand" })
  util.write_file(ledger.check_now_path(), "")
  return { queued = true, task = o.key, repo = e.repo, note = e.repo and nil or "the watcher asks which repo" }
end, { rex = false })

action("develop_discard", "stop a task and remove its worktree (its branch stays)", { task = "string" }, function(a)
  local e = target(a)
  if not ledger.ACTIVE[e.state] and e.state ~= "queued" and e.state ~= "offered" then
    error(string.format("%s is %s; there's nothing to discard", ledger.label(e), e.state), 0)
  end
  ledger.queue_answer({ task = e.id, what = "_discard", via = "cli" })
  return { queued = true, task = e.key }
end, { rex = false })

action("develop_focus", "show a task's tab in Rex", { task = "string?", item = "string?" }, function(a)
  local e = target(a)
  return require("rex_develop.tasks").focus(e)
end)

---------------------------------------------------------------------------
-- Arguments from a command line

-- key=value strings as an action's arguments, typed as its args declare.
function M.parse(spec, words)
  spec = spec or {}
  local out = {}
  for _, w in ipairs(words) do
    local k, v = w:match("^([%w_]+)=(.*)$")
    if not k then
      error(string.format("arguments look like key=value, not %s", w), 0)
    end
    local kind = spec[k]
    if not kind then
      local names = {}
      for name in pairs(spec) do
        names[#names + 1] = name
      end
      table.sort(names)
      error(string.format("unknown argument %s; this action takes %s", k, #names > 0 and table.concat(names, ", ") or "none"), 0)
    end
    kind = kind:gsub("%?$", "")
    if kind == "integer" then
      local n = tonumber(v)
      if not n or n ~= math.floor(n) then
        error(string.format("%s must be a whole number, not %s", k, v), 0)
      end
      out[k] = n
    elseif kind == "boolean" then
      if v ~= "true" and v ~= "false" then
        error(string.format("%s must be true or false, not %s", k, v), 0)
      end
      out[k] = v == "true"
    else
      out[k] = v
    end
  end
  for k, kind in pairs(spec) do
    if not kind:match("%?$") and out[k] == nil then
      error(string.format("%s is required", k), 0)
    end
  end
  return out
end

return M
