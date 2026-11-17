-- The watcher: scans the trackers, takes your answers, and moves each task
-- one step. It runs in the control tab of the rex-develop Rex session
-- (scripts/watch.lua), as LuaJIT in an ordinary pane, so it has your
-- shell's git and gh sign-ins, and spends no tokens.

local util = require("rex_develop.util")
local config = require("rex_develop.config")
local ledger = require("rex_develop.ledger")
local rules = require("rex_develop.rules")
local trackers = require("rex_develop.trackers")
local tasks = require("rex_develop.tasks")
local inbox = require("rex_develop.inbox")
local github = require("rex_develop.github")

local M = {}

-- Phases where an agent works, which count against max_tasks. A task
-- waiting on you doesn't hold a slot.
M.WORKING = { planning = true, building = true, checking = true, opening = true }

local function by_id(list)
  local out = {}
  for _, e in ipairs(list) do
    out[e.id] = e
  end
  return out
end

-- Check the trackers once and apply the rules. Returns the events. With
-- dry, nothing is saved.
function M.scan(opts)
  opts = opts or {}
  local c = config.load(true)
  local now = util.now()
  local all = ledger.list()
  local known = by_id(all)
  local evs = {}
  for _, tracker in ipairs(trackers.enabled()) do
    local tracked = {}
    for _, e in ipairs(all) do
      if e.tracker == tracker.name and not ledger.TERMINAL[e.state] then
        tracked[#tracked + 1] = tracker.name == "linear" and e.issue_id or e
      end
    end
    local obs = tracker.scan(tracked)
    for _, o in ipairs(obs) do
      local id = ledger.task_id(o.tracker, o.key)
      local e = known[id]
      local take = true
      if not e and type(c.hooks.should_take) == "function" then
        local ok, v = pcall(c.hooks.should_take, o)
        take = not ok or v ~= false
      end
      if take then
        local e2, out = rules.decide(e and util.decode(util.json(e)) or nil, o, now, c.gates.start)
        if e2 then
          e2.id = id
          e2.issue_id = o.issue_id or e2.issue_id
          e2.number = o.number or e2.number
          e2.branch = e2.branch or o.branch
          if not e2.repo then
            e2.repo = o.repo
            e2.repo_choices = (not o.repo) and o.repo_choices or nil
          end
          if not opts.dry then
            ledger.save(e2)
          end
        end
        for _, ev in ipairs(out) do
          evs[#evs + 1] = opts.dry and ev or ledger.append_event(ev)
        end
      end
    end
  end
  if not opts.dry then
    ledger.update_state(function(st)
      st.last_scan_at = now
    end)
  end
  return evs
end

-- The context every step shares: whether rex-inbox carries the asks, and
-- who you are on GitHub.
function M.context()
  local ok, login = pcall(github.login)
  return { inbox = inbox.available(), login = ok and login or nil }
end

-- Answers from rex-inbox replies and from the actions, applied in order.
local function take_answers(session, ctx, log)
  local list = {}
  if ctx.inbox then
    for _, r in ipairs(inbox.replies()) do
      list[#list + 1] = {
        task = r.ref.task, what = r.ref.what, version = r.ref.version,
        choice = r.choice, text = r.body, via = "rex-inbox", message_id = r.id,
      }
    end
  end
  util.append(list, ledger.take_answers())
  for _, ans in ipairs(list) do
    local e = ans.task and ledger.load(ans.task)
    if not e then
      e = ans.task and ledger.find(ans.task)
    end
    if e then
      local ok, applied, note = pcall(tasks.apply_answer, e, ans, session, ctx)
      if not ok then
        applied, note = false, tostring(applied)
      end
      ledger.save(e)
      log(note or "")
      if not applied and ans.via == "rex-inbox" and ans.message_id then
        inbox.reply(ans.message_id, note)
      end
    end
  end
end

local function needs(list, e, kind, text, what)
  list[#list + 1] = { task = e.id, label = ledger.label(e), title = e.title, kind = kind, what = what or kind, text = text }
end

-- One step. scan: check the trackers first. Returns attention (problems)
-- and waiting (asks), and the scan's error if it failed.
function M.step(session, scan, log)
  log = log or function() end
  local c = config.load(scan)
  local scan_error
  if scan then
    local ok, evs = pcall(M.scan)
    if not ok then
      scan_error = tostring(evs)
      log("scan failed: " .. scan_error)
    else
      for _, ev in ipairs(evs) do
        log(ledger.format_event(ev))
      end
    end
  end
  local ctx = M.context()
  take_answers(session, ctx, log)

  local attention = {}
  local all = ledger.list()
  local working = 0
  for _, e in ipairs(all) do
    local ok, err = pcall(function()
      if e.state == "active" then
        tasks.advance(e, session, ctx, attention)
        ledger.save(e)
      elseif e.state == "offered" or e.state == "queued" then
        tasks.advance_waiting(e, ctx)
        ledger.save(e)
      elseif e.state == "open" and scan then
        tasks.advance_open(e, session)
        ledger.save(e)
      end
    end)
    if not ok then
      needs(attention, e, "error", tostring(err):sub(1, 300), "step")
      log(string.format("%s: %s", ledger.label(e), tostring(err)))
    end
    if e.state == "active" and M.WORKING[e.phase] then
      working = working + 1
    end
  end

  -- Start what's queued, by priority, while there's room.
  if not ledger.paused() then
    for _, e in ipairs(rules.start_order(ledger.list())) do
      if working >= c.max_tasks then
        break
      end
      local retry_wait = e.start_failed_at and os.time() - (util.epoch(e.start_failed_at) or 0) < 300
      if e.repo and not retry_wait then
        local ok, err = pcall(tasks.start, e, session, all, ctx)
        if ok then
          working = working + 1
          log(string.format("%s: started in %s on %s", ledger.label(e), e.repo, e.branch))
        else
          e.start_error = tostring(err)
          e.start_failed_at = util.now()
          log(string.format("%s: didn't start: %s", ledger.label(e), e.start_error))
        end
        ledger.save(e)
      end
    end
  end

  -- What waits on you, and what's wrong.
  local waiting = {}
  for _, e in ipairs(ledger.list()) do
    if e.start_error and e.state == "queued" then
      needs(attention, e, "error", "didn't start: " .. e.start_error, "start-failed")
    end
    for what, a in pairs(type(e.asks) == "table" and e.asks or {}) do
      waiting[#waiting + 1] = {
        task = e.id, label = ledger.label(e), title = e.title, what = what, kind = a.kind,
        subject = a.subject, options = a.options, version = a.version,
        message_id = a.message_id, asked_at = a.asked_at, error = a.send_error or a.share_error,
      }
    end
  end
  table.sort(waiting, function(a, b)
    return (a.asked_at or "") < (b.asked_at or "")
  end)
  return attention, waiting, scan_error, ctx
end

---------------------------------------------------------------------------
-- The session and its watcher pane

local function rex_cli(args)
  return util.run(util.append({ "rex" }, args))
end

local function sessions()
  return (util.decode(rex_cli({ "api", "call", "session.list", "{}" }).stdout) or {}).sessions or {}
end

local function label_block(sid, bid, label)
  rex_cli({ "api", "call", "session.set_block_label", util.json({ session_id = sid, block_id = bid, label = label }) })
end

-- The watcher's command: LuaJIT on scripts/watch.lua, restarted when it
-- stops, with any REX_DEVELOP_* folders this process was given.
local function watcher_loop()
  local luajit = util.trim(util.run({ "/bin/sh", "-c", "command -v luajit" }, { check = false }).stdout)
  if luajit == "" then
    error("luajit isn't on PATH: brew install luajit", 0)
  end
  local env = {}
  for _, k in ipairs({ "REX_DEVELOP_CONFIG_DIR", "REX_DEVELOP_STATE_DIR", "REX_DEVELOP_DATA_DIR", "REX_DEVELOP_CACHE_DIR", "REX_INBOX_SOCKET", "REX_INBOX_STATE" }) do
    local v = os.getenv(k)
    if v and v ~= "" then
      env[#env + 1] = string.format("%s='%s'", k, v:gsub("'", "'\\''"))
    end
  end
  local prefix = #env > 0 and ("env " .. table.concat(env, " ") .. " ") or ""
  return string.format(
    "while :; do %s'%s' '%s/scripts/watch.lua'; echo \"watcher stopped ($?); restarting in 10s\"; sleep 10; done",
    prefix, luajit, config.ROOT)
end

-- Make sure the session exists with a running watcher.
function M.up()
  local c = config.load(true)
  local st = ledger.load_state()
  local sid
  local list = sessions()
  for _, s in ipairs(list) do
    if st.session_id and s.session_id == st.session_id then
      sid = s.session_id
    end
  end
  if not sid then
    for _, s in ipairs(list) do
      if s.label == c.session then
        sid = s.session_id
      end
    end
  end
  if not sid then
    local j = util.decode(rex_cli({ "new", c.session, "--window", "control", "-c", util.HOME, "--json", "--", "/bin/sh", "-c", watcher_loop() }).stdout)
    sid = j.session_id
    label_block(sid, j.initial_windows[1].block_ids[1], "watcher")
    ledger.update_state(function(s)
      s.session_id = sid
      s.stopped = nil
    end)
    return { session_id = sid, created = "session" }
  end
  ledger.update_state(function(s)
    s.session_id = sid
    s.stopped = nil
  end)
  local blocks = util.decode(rex_cli({ "block", "ls", "-s", sid, "--json" }).stdout).blocks or {}
  for _, b in ipairs(blocks) do
    if b.label == "watcher" then
      local p = util.decode(rex_cli({ "block", "call", "-s", sid, "-b", b.block_id, "process" }).stdout) or {}
      if p.child and p.last_exit == nil then
        return { session_id = sid, created = false }
      end
      rex_cli({ "block", "close", "-s", sid, b.block_id })
    end
  end
  local j = util.decode(rex_cli({ "window", "new", "-s", sid, "control", "-c", util.HOME, "--focus=false", "--json", "--", "/bin/sh", "-c", watcher_loop() }).stdout)
  label_block(sid, j.block_ids[1], "watcher")
  return { session_id = sid, created = "watcher" }
end

-- Close the watcher's pane. Task tabs stay open.
function M.down()
  local st = ledger.load_state()
  local closed = {}
  if st.session_id then
    local ok, res = pcall(rex_cli, { "block", "ls", "-s", st.session_id, "--json" })
    for _, b in ipairs(ok and (util.decode(res.stdout) or {}).blocks or {}) do
      if b.label == "watcher" then
        rex_cli({ "block", "close", "-s", st.session_id, b.block_id })
        closed[#closed + 1] = b.block_id
      end
    end
  end
  ledger.update_state(function(s)
    s.stopped = true
  end)
  return { closed = closed }
end

---------------------------------------------------------------------------
-- Status and the doctor

function M.status()
  local w = ledger.load_watcher() or {}
  local st = ledger.load_state()
  local out = { paused = st.paused == true, last_scan_at = st.last_scan_at, watcher_at = w.at, inbox = w.inbox, tasks = {} }
  for _, e in ipairs(ledger.list()) do
    out.tasks[#out.tasks + 1] = {
      key = e.key, label = ledger.label(e), title = e.title, state = e.state, phase = e.phase,
      repo = e.repo, branch = e.branch, pr = e.pr and e.pr.url or nil, trigger = e.trigger,
      asks = (function()
        local list = {}
        for what in pairs(type(e.asks) == "table" and e.asks or {}) do
          list[#list + 1] = what
        end
        table.sort(list)
        return list
      end)(),
    }
  end
  out.attention = w.attention or {}
  out.waiting = w.waiting or {}
  return out
end

function M.doctor()
  local checks = {}
  local function check(name, fn)
    local ok, detail = pcall(fn)
    checks[#checks + 1] = { check = name, ok = ok and detail ~= false, detail = ok and (type(detail) == "string" and detail or nil) or tostring(detail) }
  end
  local c
  check("config", function()
    c = config.load(true)
    return config.path()
  end)
  if not c then
    return { ok = false, checks = checks }
  end
  local function on_path(p)
    local r = util.run({ "/bin/sh", "-c", "command -v " .. p }, { check = false })
    if not r.ok then
      error(p .. " isn't on PATH", 0)
    end
    return util.trim(r.stdout)
  end
  for _, p in ipairs({ "git", "gh", "curl", "luajit", "rex" }) do
    check(p, function()
      return on_path(p)
    end)
  end
  check("gh signed in", function()
    return "as " .. github.login()
  end)
  for _, role in ipairs({ "builder", "checker" }) do
    check(role .. " (" .. c[role].agent .. ")", function()
      return on_path(require("rex_develop.agents").program(c[role].agent))
    end)
  end
  check("rex-inbox", function()
    if c.inbox == false then
      return "off in the config"
    end
    local r = util.run({ "rex-inbox", "status" }, { check = false })
    if not r.ok then
      if c.inbox == true then
        error("its hub isn't running: rex-inbox up", 0)
      end
      return "not running; asks show as status records and in rex-develop ls"
    end
    local help = util.run({ "rex-inbox", "send", "--help" }, { check = false }).stdout or ""
    if not help:find("--option", 1, true) then
      error("running, but too old: rex-develop needs answer options on messages, and a tool's pane that messages you as itself. Until then, asks show as status records and in rex-develop ls", 0)
    end
    return "running; asks arrive as messages"
  end)
  for _, r in ipairs(c.repo_list) do
    check("repo " .. r.slug, function()
      if not util.exists(r.checkout .. "/.git") then
        error(r.checkout .. " isn't a git clone", 0)
      end
      local url = util.trim(util.run({ "git", "-C", r.checkout, "remote", "get-url", "origin" }).stdout)
      local norm = url:gsub("%.git$", "")
      if not (norm:find(r.slug, 1, true)) then
        error(string.format("%s's origin is %s, not %s", r.checkout, url, r.slug), 0)
      end
      return r.checkout
    end)
  end
  if c.trackers.linear then
    check("linear", function()
      local lin = trackers.get("linear")
      local data = lin.graphql("query { viewer { id name } }", {})
      return "signed in as " .. tostring(data.viewer and data.viewer.name)
    end)
  end
  local ok = true
  for _, ch in ipairs(checks) do
    ok = ok and ch.ok
  end
  return { ok = ok, checks = checks }
end

return M
