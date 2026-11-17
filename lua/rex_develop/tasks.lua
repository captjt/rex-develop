-- A task, step by step: prep its worktree and context, start the builder,
-- take it through the plan, the build and the check, ask you what only you
-- can answer, open the PR, and clean up.
--
-- A task that's working is `active`, in one of these phases:
--
--   planning        the builder reads the issue and writes the plan
--   not_ready       the builder says the issue can't be built as written
--   plan_gate       the plan waits for your approval
--   building        the builder builds (and fixes what the checker found)
--   checking        the checker checks the branch against the plan
--   preview_gate    a preview waits for your look
--   open_gate       the PR waits for your approval
--   opening         approved: the watcher pushes and opens it
--
-- Then it's `open` until the PR merges or closes. Each agent writes one
-- line to its status file in the worktree:
--
--   .tmp/status.txt          the builder: WORKING …, PLAN_READY,
--                            NOT_READY: <why>, DECISION D<n>, BUILT,
--                            BLOCKED: <why>
--   .tmp/checker-status.txt  the checker: CHECKING <n>, CHECKED, BLOCKED: <why>
--
-- What waits on you is an "ask" on the task (e.asks), keyed by what it is:
-- start, repo, not_ready, plan, preview, open, issue_changed, or a decision
-- (D1, …). Each is sent as a rex-inbox message when rex-inbox runs, and is
-- shown as a status record and by `rex-develop ls` either way. An answer
-- names the ask and its version, so one that comes after the ask moved on
-- changes nothing.

local util = require("rex_develop.util")
local config = require("rex_develop.config")
local ledger = require("rex_develop.ledger")
local trackers = require("rex_develop.trackers")
local agents = require("rex_develop.agents")
local decisions = require("rex_develop.decisions")
local plan = require("rex_develop.plan")
local inbox = require("rex_develop.inbox")
local github = require("rex_develop.github")

local M = {}

---------------------------------------------------------------------------
-- Panes

local function rex_agent(args)
  return util.append({ config.ROOT .. "/bin/rex-agent" }, args)
end

-- rex-agent takes pane names of [a-z][a-z0-9_-]{0,31}.
function M.pane(e)
  local p = ledger.label(e):lower():gsub("[^a-z0-9_-]", "-"):gsub("%-+", "-")
  if not p:match("^[a-z]") then
    p = "t-" .. p
  end
  return p:sub(1, 25)
end

function M.checker_pane(e)
  return M.pane(e) .. "-check"
end

-- The pane's state (idle, working, done, blocked, error) and block id, or
-- nil when it's gone.
function M.pane_state(session, name)
  if not name or not session then
    return nil
  end
  local res = util.run(rex_agent({ "get", name, "-s", session }), { check = false })
  if not res.ok then
    return nil
  end
  local j = util.decode(res.stdout) or {}
  return j.state, j.block_id
end

function M.close_pane(session, name)
  if name and session then
    util.run(rex_agent({ "close", name, "-s", session }), { check = false })
  end
end

-- Paste a prompt into an agent that isn't working. Returns true when it
-- went in; false when the agent is busy, so the caller tries next step.
function M.prompt(session, name, text)
  local res = util.run(rex_agent({ "prompt", name, "-s", session, "-" }), { check = false, input = text })
  if res.ok then
    return true
  end
  if res.code == 7 or res.code == 3 then
    return false
  end
  error(string.format("%s didn't take the prompt: %s", name, util.trim(res.stderr):sub(1, 300)), 0)
end

---------------------------------------------------------------------------
-- Files in the worktree

function M.worktree_path(e)
  return config.DATA_DIR .. "/worktrees/" .. e.id
end

local function tmp(e, rel)
  return e.worktree .. "/.tmp/" .. rel
end

function M.status(e, which)
  local s = util.read_file(tmp(e, which == "checker" and "checker-status.txt" or "status.txt")) or ""
  return util.trim(s:match("^[^\n]*") or "")
end

function M.set_status(e, which, s)
  util.write_file(tmp(e, which == "checker" and "checker-status.txt" or "status.txt"), s .. "\n")
end

local function git(e, args, opts)
  return util.run(util.append({ "git", "-C", e.worktree }, args), opts)
end

local function head(e)
  return util.trim(git(e, { "rev-parse", "HEAD" }).stdout)
end

---------------------------------------------------------------------------
-- Asks: what waits on you

local GATES = {
  start = { "Start", "Skip", "Not this cycle" },
  not_ready = { "Proceed", "Drop" },
  plan = { "Approve", "Revise", "Discard" },
  preview = { "Looks right", "Needs work" },
  open = { "Open PR", "Needs changes", "Discard" },
  issue_changed = { "Stop", "Keep going" },
}
-- The option a reply with only text means.
local TEXT_MEANS = { not_ready = 1, plan = 2, preview = 2, open = 2 }

-- Put an ask on the task, and send it if rex-inbox runs. A new ask for the
-- same thing replaces the old one, with the next version.
function M.ask(e, what, kind, subject, body, options, ctx)
  e.asks = type(e.asks) == "table" and e.asks or {}
  local old = e.asks[what]
  local a = {
    what = what, kind = kind, subject = subject, body = body, options = options,
    version = (old and old.version or 0) + 1, asked_at = util.now(),
  }
  e.asks[what] = a
  M.send_ask(e, a, ctx)
  ledger.append_event({ kind = "asked", task = e.key, note = what })
  return a
end

-- Send an ask that hasn't gone out, when rex-inbox runs.
function M.send_ask(e, a, ctx)
  if a.message_id or not (ctx and ctx.inbox) then
    return
  end
  local ok, id = pcall(inbox.send, a.subject, a.body, a.options)
  if ok then
    a.message_id = id
    a.sent_at = util.now()
    ledger.remember_thread(id, { task = e.id, what = a.what, version = a.version })
  else
    a.send_error = tostring(id)
  end
end

local function close_ask(e, what)
  if type(e.asks) == "table" then
    e.asks[what] = nil
  end
end

-- A note to you with nothing to answer, such as a PR that opened.
local function tell(e, subject, body, ctx)
  if ctx and ctx.inbox then
    pcall(inbox.send, subject, body, nil)
  end
end

---------------------------------------------------------------------------
-- The builder's queue of prompts: answers and notes it gets when it's
-- next free to take them.

local function queue_prompt(e, text)
  e.outbox = type(e.outbox) == "table" and e.outbox or {}
  e.outbox[#e.outbox + 1] = text
end

local function has_outbox(e)
  return type(e.outbox) == "table" and #e.outbox > 0
end

-- Send everything queued for the builder, if it's free. Returns true when
-- it went.
local function flush_outbox(e, session, preface, suffix)
  if not has_outbox(e) then
    return false
  end
  local lines = { preface or "Updates from rex-develop while you worked:", "" }
  for _, t in ipairs(e.outbox) do
    lines[#lines + 1] = "- " .. t
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = suffix or "Take these into account. When you're done, write the status your task asks for: PLAN_READY while planning, BUILT while building."
  local prev = M.status(e, "builder")
  M.set_status(e, "builder", "WORKING on updates")
  if M.prompt(session, e.pane, table.concat(lines, "\n")) then
    e.outbox = {}
    return true
  end
  M.set_status(e, "builder", prev)
  return false
end

---------------------------------------------------------------------------
-- Briefs

local function brief(name)
  local mine = config.CONFIG_DIR .. "/briefs/" .. name
  return util.read_file(mine) or assert(util.read_file(config.ROOT .. "/briefs/" .. name), "missing brief " .. name)
end

local function section(title, text)
  if not text or util.trim(text) == "" then
    return ""
  end
  return "## " .. title .. "\n\n" .. util.trim(text) .. "\n"
end

function M.vars(e)
  local c = config.load()
  local tracker = trackers.get(e.tracker)
  local repo = c.repos[e.repo]
  local mode = e.plan_mode
  return {
    KEY = e.key,
    LABEL = ledger.label(e),
    TITLE = e.title or "",
    URL = e.url or "",
    TRACKER = e.tracker == "linear" and "Linear" or "GitHub",
    REPO = e.repo,
    BRANCH = e.branch,
    BASE = e.base,
    PORT = e.port,
    LOGIN = e.login or "you",
    MAX_DECISIONS = c.max_decisions,
    CLOSES = tracker.closes(e),
    PLAN_FORMAT = config.guide(e.repo, "plan_format") or "",
    PR_STYLE = config.guide(e.repo, "pr_style") or "Plain, short sentences. Say what changes and why.",
    PLAN_GUIDE = section("More on planning", config.guide(e.repo, "plan")),
    BUILD_GUIDE = section("More on building", config.guide(e.repo, "build")),
    CHECK_GUIDE = section("More on checking", config.guide(e.repo, "check")),
    REPO_NOTES = section("Notes on " .. e.repo, repo and repo.notes),
    PLAN_MODE = mode == "summary"
      and "This repo is public and the issue may not be, so the plan goes on the PR in summary: write Intent, Acceptance and Out of scope in your own words, without quoting the issue or its comments, and leave Notes for things that are safe to publish."
      or (mode == false and "This repo doesn't attach plans to PRs, but write the plan all the same: you and the checker work from it."
      or "The Intent, Acceptance, Out of scope and Notes sections go on the PR as they are, for its reviewers."),
  }
end

local function write_briefs(e)
  local vars = M.vars(e)
  util.mkdirp(tmp(e, "tasks"))
  util.write_file(tmp(e, "ground-rules.md"), util.render(brief("ground-rules.md"), vars))
  for _, name in ipairs({ "plan.md", "build.md", "check.md" }) do
    util.write_file(tmp(e, "tasks/" .. name), util.render(brief(name), vars))
  end
end

---------------------------------------------------------------------------
-- Starting

local PORT_BASE, PORT_MAX = 4310, 4399

local function free_port(tasks)
  local taken = {}
  for _, t in ipairs(tasks) do
    if ledger.ACTIVE[t.state] and t.port then
      taken[t.port] = true
    end
  end
  for p = PORT_BASE, PORT_MAX do
    if not taken[p] then
      return p
    end
  end
  return PORT_BASE
end

local function default_base(checkout)
  local res = util.run({ "git", "-C", checkout, "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, { check = false })
  local b = util.trim(res.stdout):match("^origin/(.+)$")
  return b or "main"
end

-- The worktree on the task's branch, from a fresh base, and the context.
function M.prep(e)
  local c = config.load()
  local repo = c.repos[e.repo]
  if not repo then
    error(string.format("%s builds in %s, which isn't in the config's repos", ledger.label(e), tostring(e.repo)), 0)
  end
  local checkout = repo.checkout
  if not util.exists(checkout .. "/.git") then
    error(string.format("%s's checkout %s isn't a git clone", e.repo, checkout), 0)
  end
  local function g(args, opts)
    return util.run(util.append({ "git", "-C", checkout }, args), opts)
  end
  g({ "fetch", "--quiet", "--no-tags", "origin" })
  e.base = e.base or repo.base or default_base(checkout)
  local tracker = trackers.get(e.tracker)
  e.branch = e.branch or tracker.branch(e)
  e.worktree = e.worktree or M.worktree_path(e)
  if not util.exists(e.worktree .. "/.git") then
    local remote = util.trim(g({ "ls-remote", "--heads", "origin", e.branch }).stdout)
    if remote ~= "" then
      error(string.format("the branch %s is already on origin; rex-develop won't build over someone's branch. Delete it, or start the task by hand once it's yours", e.branch), 0)
    end
    util.mkdirp(e.worktree:match("^(.*)/[^/]+$"))
    if g({ "rev-parse", "--verify", "--quiet", "refs/heads/" .. e.branch }, { check = false }).ok then
      g({ "worktree", "add", "--quiet", e.worktree, e.branch })
    else
      g({ "worktree", "add", "--quiet", "--no-track", "-b", e.branch, e.worktree, "origin/" .. e.base })
    end
  end
  e.base_head = util.trim(g({ "rev-parse", "origin/" .. e.base }).stdout)
  for _, d in ipairs({ "context", "decisions", "check", "tasks" }) do
    util.mkdirp(tmp(e, d))
  end
  local info = tracker.context(e, tmp(e, "context"))
  e.comments_seen = info.comments or e.comments_seen
  if repo.notes then
    util.write_file(tmp(e, "context/repo-notes.md"), repo.notes .. "\n")
  end
  local ok_pub, public = pcall(github.is_public, e.repo)
  e.repo_public = ok_pub and public or false
  e.plan_mode = config.plan_mode(e.repo, e.repo_public)
end

-- Open an agent's pane and give it its first prompt. role is "builder" or
-- "checker". The builder gets a new tab; the checker splits beside it.
local function open_agent(e, role, session, prompt)
  local spec = config.agent_for(e.repo, role)
  local name = role == "builder" and M.pane(e) or M.checker_pane(e)
  local argv = rex_agent({ "start", name, "-s", session, "--cwd", e.worktree, "--timeout", "180", "--kind", "env" })
  local anchor = role == "checker" and select(2, M.pane_state(session, e.pane)) or nil
  if anchor then
    util.append(argv, { "--anchor", anchor })
  else
    argv[#argv + 1] = "--tab"
  end
  argv[#argv + 1] = "--"
  util.append(argv, agents.env_args(e.worktree))
  e[role .. "_agent"] = spec.agent
  local since = os.time()
  util.append(argv, agents.command(e, role, spec, e.worktree, agents.writable_dirs(config.load().repos[e.repo].checkout)))
  local res = util.run(argv, { check = false })
  if not res.ok then
    M.close_pane(session, name)
    if ((res.stdout or "") .. (res.stderr or "")):find("Hooks need review", 1, true) then
      error("Codex is waiting for its hooks to be trusted. Run codex once, open /hooks, and trust them; the task retries on its own.", 0)
    end
    error(string.format("the %s (%s) didn't start: %s", role, spec.agent, util.trim(res.stderr ~= "" and res.stderr or res.stdout):sub(1, 300)), 0)
  end
  e[role .. "_session"] = agents.session_after_start(e, role, spec, e.worktree, since)
  if role == "builder" then
    e.pane = name
  else
    e.checker_pane = name
  end
  for _ = 1, 10 do
    if M.prompt(session, name, prompt) then
      return
    end
    util.sleep(3)
  end
  error(name .. " never took its first prompt", 0)
end

-- Start a queued task: prep, briefs, and the builder.
function M.start(e, session, tasks, ctx)
  if not session then
    error("there's no Rex session to open the task in; run rex-develop up", 0)
  end
  e.login = ctx and ctx.login or e.login
  e.port = e.port or free_port(tasks or {})
  M.prep(e)
  write_briefs(e)
  M.set_status(e, "builder", "WORKING planning")
  open_agent(e, "builder", session, "Read .tmp/ground-rules.md, then .tmp/tasks/plan.md, and do the task.")
  e.state = "active"
  e.phase = "planning"
  e.round = 1
  e.session_id = session
  e.started_at = util.now()
  e.start_error, e.start_failed_at = nil, nil
  ledger.append_event({ kind = "started", task = e.key, note = e.repo .. " on " .. e.branch })
end

---------------------------------------------------------------------------
-- Decisions the builder raised

local function scan_decisions(e, ctx)
  e.decisions = type(e.decisions) == "table" and e.decisions or {}
  e.bad_decisions = type(e.bad_decisions) == "table" and e.bad_decisions or {}
  local label = ledger.label(e)
  for _, f in ipairs(decisions.pending_files(e.worktree)) do
    local known = e.decisions[f.id]
    if not known then
      local raw = util.decode(util.read_file(f.path))
      local d, why = decisions.validate(raw, f.name)
      if d then
        e.bad_decisions[f.name] = nil
        e.decisions[f.id] = {
          question = d.question, options = d.options, recommend = d.recommend, mode = d.mode,
          why = d.why, meanwhile = d.meanwhile, raised_at = util.now(), phase = e.phase,
        }
        local m = decisions.message(label, d)
        M.ask(e, f.id, "decision", m.subject, m.body, m.options, ctx)
        ledger.append_event({ kind = "decision", task = e.key, note = f.id .. ": " .. d.question })
      elseif e.bad_decisions[f.name] ~= why then
        e.bad_decisions[f.name] = why
        queue_prompt(e, string.format(".tmp/decisions/%s isn't valid: %s. Fix the file; rex-develop picks it up as soon as it is.", f.name, why))
      end
    end
  end
end

-- Record an answer to decision id: in the ledger, in its answer file, and
-- for the builder.
local function answer_decision(e, id, parsed, via)
  local d = e.decisions[id]
  local a = { id = id, by = "you", via = via, at = util.now(), text = parsed.text }
  if parsed.choice then
    a.choice = parsed.choice - 1
    a.label = d.options[parsed.choice].label
  else
    a.label = "Another answer"
  end
  d.answer = a
  decisions.write_answer(e.worktree, id, a)
  ledger.append_event({ kind = "decided", task = e.key, note = id .. ": " .. a.label })
  -- Before the plan's approved, the approval carries every answer; after,
  -- the builder hears now.
  if e.phase ~= "plan_gate" and e.phase ~= "not_ready" then
    queue_prompt(e, decisions.answer_line(id, d, a) .. " Its answer is in .tmp/decisions/" .. id .. ".answer.json.")
  end
end

-- Every decision without an answer takes its recommendation.
local function stand_recommendations(e)
  for id, d in pairs(e.decisions or {}) do
    if not d.answer then
      local a = { id = id, choice = d.recommend, label = d.options[d.recommend + 1].label, stood = true, at = util.now() }
      d.answer = a
      decisions.write_answer(e.worktree, id, a)
      close_ask(e, id)
    end
  end
end

local function decision_lines(e)
  local ids = {}
  for id in pairs(e.decisions or {}) do
    ids[#ids + 1] = id
  end
  table.sort(ids, function(a, b)
    return tonumber(a:sub(2)) < tonumber(b:sub(2))
  end)
  local out = {}
  for _, id in ipairs(ids) do
    local d = e.decisions[id]
    if d.answer then
      out[#out + 1] = "- " .. decisions.answer_line(id, d, d.answer)
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Gates

local function approve_plan(e, session, by)
  stand_recommendations(e)
  e.plan_approved_by = by
  e.plan_approved_at = util.now()
  local lines = { "The plan is approved." }
  local ds = decision_lines(e)
  if #ds > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "The decisions, as they stand (each answer is also in .tmp/decisions/):"
    util.append(lines, ds)
  end
  if has_outbox(e) then
    lines[#lines + 1] = ""
    for _, t in ipairs(e.outbox) do
      lines[#lines + 1] = "- " .. t
    end
    e.outbox = {}
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Now read .tmp/tasks/build.md and do it."
  M.set_status(e, "builder", "WORKING building")
  e.phase = "building"
  if not M.prompt(session, e.pane, table.concat(lines, "\n")) then
    -- Busy: say it again next step.
    e.pending_prompt = table.concat(lines, "\n")
  end
  ledger.append_event({ kind = "plan-approved", task = e.key, note = by and ("by @" .. by) or "automatically" })
end

local function send_builder(e, session, text, status)
  M.set_status(e, "builder", status or "WORKING")
  if not M.prompt(session, e.pane, text) then
    e.pending_prompt = text
  end
end

function M.discard(e, why, session)
  session = session or e.session_id
  M.close_pane(session, e.checker_pane)
  M.close_pane(session, e.pane)
  if e.preview_port then
    pcall(inbox.stop_share, e.preview_port)
  end
  M.remove_worktree(e, false)
  e.state = "discarded"
  e.phase = nil
  e.asks = {}
  e.discarded_reason = why
  e.ended_at = util.now()
  ledger.append_event({ kind = "discarded", task = e.key, note = why })
end

-- Remove the task's worktree. The branch stays unless drop_branch, so a
-- discarded task's commits are never lost.
function M.remove_worktree(e, drop_branch)
  local repo = config.load().repos[e.repo]
  if not repo or not e.worktree then
    return
  end
  if util.exists(e.worktree) then
    util.run({ "git", "-C", repo.checkout, "worktree", "remove", "--force", e.worktree }, { check = false })
  end
  if drop_branch and e.branch then
    util.run({ "git", "-C", repo.checkout, "branch", "-D", e.branch }, { check = false })
  end
end

-- What a task is doing, in words, for a note to you.
local DOING = {
  planning = "being planned", not_ready = "waiting on whether it's ready", plan_gate = "waiting on its plan",
  building = "being built", checking = "being checked", preview_gate = "waiting on its preview",
  open_gate = "waiting to open", opening = "opening",
}

-- Why an answer came too late: the ask it answers is gone or replaced.
local function stale_note(e, what)
  local label = ledger.label(e)
  local d = type(e.decisions) == "table" and e.decisions[what] or nil
  if d and d.answer then
    return string.format("%s %s already has its answer: %s. Nothing changed.", label, what, d.answer.label)
  end
  if e.state ~= "active" then
    return string.format("%s is %s now. Nothing changed.", label, e.state)
  end
  if type(e.asks) == "table" and e.asks[what] then
    return string.format("%s asked about %s again since; answer the newer message. Nothing changed.", label, what)
  end
  return string.format("%s isn't waiting on that any more; it's %s. Nothing changed.", label, DOING[e.phase] or e.phase or e.state)
end

-- Apply an answer: { what, version?, choice?, text?, via }. Returns a note
-- for whoever answered: what happened, or why nothing did.
function M.apply_answer(e, ans, session, ctx)
  local a = type(e.asks) == "table" and e.asks[ans.what] or nil
  local label = ledger.label(e)
  if ans.what == "_discard" then
    if ledger.TERMINAL[e.state] then
      return false, string.format("%s is already %s.", label, e.state)
    end
    M.discard(e, "you discarded it", session)
    return true, label .. ": discarded. Its branch stays."
  end
  if not a or (ans.version and tonumber(ans.version) ~= a.version) then
    return false, stale_note(e, ans.what)
  end
  local labels = a.options or {}
  local parsed = decisions.parse_reply(labels, { choice = ans.choice, body = ans.text })
  if a.kind == "decision" then
    if not parsed.choice and not parsed.text then
      return false, label .. ": an empty answer; answer with a button, a number, or your own words."
    end
    answer_decision(e, a.what, parsed, ans.via)
    close_ask(e, a.what)
    return true, string.format("%s %s: %s.", label, a.what, e.decisions[a.what].answer.label)
  end

  local choice = parsed.choice or (parsed.text and TEXT_MEANS[a.what]) or nil
  if a.what == "repo" then
    choice = parsed.choice
  end
  if not choice then
    return false, string.format("%s: answer with %s.", label, table.concat(labels, ", "))
  end
  local picked = labels[choice]
  local text = parsed.text
  close_ask(e, a.what)
  ledger.append_event({ kind = "answered", task = e.key, note = a.what .. ": " .. picked })

  if a.what == "start" then
    if picked == "Start" then
      e.state, e.queued_at = "queued", util.now()
    elseif picked == "Skip" then
      e.state = "skipped"
    else
      e.state, e.deferred_cycle = "deferred", e.cycle_id
    end
  elseif a.what == "repo" then
    e.repo = picked
    e.state, e.queued_at = "queued", util.now()
  elseif a.what == "issue_changed" then
    if picked == "Stop" then
      M.discard(e, "stopped: " .. tostring(e.issue_changed), session)
    else
      e.issue_changed_kept, e.issue_changed = e.issue_changed, nil
    end
  elseif a.what == "not_ready" then
    if picked == "Drop" then
      M.discard(e, "you dropped it as not ready", session)
    else
      e.phase = "planning"
      send_builder(e, session, "Proceed: plan on the assumptions you stated, and mark each one in the plan's Notes."
        .. (text and ("\n\nFrom " .. (e.login and ("@" .. e.login) or "the person") .. ': "' .. text .. '"') or "")
        .. "\n\nWrite the plan as .tmp/tasks/plan.md says, then write PLAN_READY.", "WORKING planning")
    end
  elseif a.what == "plan" then
    if picked == "Approve" then
      approve_plan(e, session, e.login)
    elseif picked == "Revise" then
      e.phase = "planning"
      send_builder(e, session, "Revise the plan. " .. (text and ('The answer was: "' .. text .. '"') or "No more was said; look again at what's weakest.")
        .. "\n\nUpdate .tmp/plan.md (and add decisions if it raises any), then write PLAN_READY again.", "WORKING revising the plan")
    else
      M.discard(e, "you discarded the plan", session)
    end
  elseif a.what == "preview" then
    if picked == "Looks right" then
      e.previewed_head = e.checked_head
      e.phase = "open_gate"
    else
      e.phase = "building"
      e.preview_feedback = (e.preview_feedback or 0) + 1
      send_builder(e, session, "The preview needs work: " .. (text or "no detail was given; look at it again yourself.")
        .. "\n\nFix it, commit, and write BUILT. The checker checks it again.", "WORKING on the preview")
    end
    if e.preview_port then
      pcall(inbox.stop_share, e.preview_port)
      e.preview_port = nil
    end
  elseif a.what == "open" then
    if picked == "Open PR" then
      e.phase = "opening"
      e.open_approved_by = e.login
    elseif picked == "Needs changes" then
      e.phase = "building"
      send_builder(e, session, "Before the PR opens, this needs changes: " .. (text or "no detail was given.")
        .. "\n\nMake them, commit, update .tmp/pr.json if the description changes, and write BUILT. The checker checks it again.", "WORKING on changes")
    else
      M.discard(e, "you discarded it before it opened", session)
    end
  end
  return true, string.format("%s: %s.", label, picked)
end

---------------------------------------------------------------------------
-- The check

local function start_check(e, session, ctx)
  e.check_n = (e.check_n or 0) + 1
  e.built_head = head(e)
  M.set_status(e, "checker", "CHECKING " .. e.check_n)
  local prompt
  if e.check_n == 1 or not M.pane_state(session, e.checker_pane) then
    prompt = string.format("Read .tmp/ground-rules.md, then .tmp/tasks/check.md, and do it. This is check %d.", e.check_n)
    open_agent(e, "checker", session, prompt)
  else
    prompt = string.format("The builder changed the branch since your last check (%s..%s). Check it again as .tmp/tasks/check.md says. This is check %d: write .tmp/check/check-%d.json.",
      util.short(e.last_checked_head), util.short(e.built_head), e.check_n, e.check_n)
    if not M.prompt(session, e.checker_pane, prompt) then
      e.check_n = e.check_n - 1
      return false
    end
  end
  e.phase = "checking"
  ledger.append_event({ kind = "checking", task = e.key, note = "check " .. e.check_n })
  return true
end

local function read_check(e)
  local j = util.decode(util.read_file(tmp(e, string.format("check/check-%d.json", e.check_n))))
  if type(j) ~= "table" then
    return nil
  end
  j.findings = util.list(j.findings)
  return j
end

local function commits(e)
  local out = git(e, { "log", "--oneline", "--no-decorate", e.base_head .. "..HEAD" }, { check = false }).stdout or ""
  local list = {}
  for l in out:gmatch("[^\n]+") do
    list[#list + 1] = l
  end
  return list
end

local function tmp_paths_in_diff(e)
  local out = git(e, { "diff", "--name-only", e.base_head .. "..HEAD" }, { check = false }).stdout or ""
  local bad = {}
  for p in out:gmatch("[^\n]+") do
    if p:match("^%.tmp/") then
      bad[#bad + 1] = p
    end
  end
  return bad
end

local function read_pr(e)
  local j = util.decode(util.read_file(tmp(e, "pr.json")))
  if type(j) ~= "table" or type(j.title) ~= "string" or util.trim(j.title) == "" or type(j.body) ~= "string" then
    return nil
  end
  return j
end

-- The checks a built branch must pass before the checker sees it. Returns
-- a problem for the builder, or nil.
local function built_problem(e)
  if #commits(e) == 0 then
    return string.format("there are no commits on %s past %s. Commit the work (Conventional Commits), then write BUILT.", e.branch, e.base)
  end
  local bad = tmp_paths_in_diff(e)
  if #bad > 0 then
    return "the commits include files under .tmp/, which is rex-develop's and never ships: " .. table.concat(bad, ", ") .. ". Take them out of the commits, then write BUILT."
  end
  if not read_pr(e) then
    return ".tmp/pr.json is missing or has no title and body. Write it as .tmp/tasks/build.md says, then write BUILT."
  end
end

---------------------------------------------------------------------------
-- Moving a task one step

local function needs(list, e, kind, text, what)
  list[#list + 1] = { task = e.id, label = ledger.label(e), title = e.title, kind = kind, what = what or kind, text = text }
end

local function plan_message(e, md)
  local open = {}
  for id, d in pairs(e.decisions or {}) do
    if not d.answer then
      open[#open + 1] = string.format("%s: %s (recommended: %s)", id, d.question, d.options[d.recommend + 1].label)
    end
  end
  table.sort(open)
  local acc = plan.section(md, "Acceptance") or ""
  local n_acc = select(2, acc:gsub("\n%s*[-*%d]", "")) + (acc:match("^%s*[-*%d]") and 1 or 0)
  local subject = decisions.cut(string.format("%s · plan · %d acceptance item%s, %d decision%s open%s",
    ledger.label(e), n_acc, n_acc == 1 and "" or "s", #open, #open == 1 and "" or "s",
    e.plan_version > 1 and (" · revision " .. (e.plan_version - 1)) or ""), 140)
  local body = { util.trim(md), "" }
  if #open > 0 then
    body[#body + 1] = "Open decisions (each is its own message). Approve accepts the recommendation for any you haven't answered:"
    for _, l in ipairs(open) do
      body[#body + 1] = "- " .. l
    end
    body[#body + 1] = ""
  end
  body[#body + 1] = "Approve, Revise (say what to change), or Discard."
  return subject, table.concat(body, "\n")
end

local function open_message(e, check)
  local pr = read_pr(e) or { title = "(no title)", body = "" }
  local cs = commits(e)
  local stood = 0
  for _, d in pairs(e.decisions or {}) do
    if d.answer and d.answer.stood then
      stood = stood + 1
    end
  end
  local left = check and check.verdict == "fix" and #check.findings or 0
  local bits = { string.format("%d commit%s", #cs, #cs == 1 and "" or "s") }
  bits[#bits + 1] = left == 0 and "checked" or string.format("%d finding%s left", left, left == 1 and "" or "s")
  if stood > 0 then
    bits[#bits + 1] = string.format("%d recommendation%s stood", stood, stood == 1 and "" or "s")
  end
  local subject = decisions.cut(string.format("%s · ready to open · %s", ledger.label(e), table.concat(bits, ", ")), 140)
  local body = { pr.title, "", plan.strip(pr.body), "", "Commits:" }
  for _, l in ipairs(cs) do
    body[#body + 1] = "- " .. l
  end
  if check and check.summary then
    body[#body + 1] = ""
    body[#body + 1] = "The checker: " .. tostring(check.summary)
  end
  if left > 0 then
    body[#body + 1] = ""
    body[#body + 1] = "Still open after " .. e.fix_loops_used .. " fix rounds:"
    for _, f in ipairs(check.findings) do
      body[#body + 1] = string.format("- %s: %s", tostring(f.id or "?"), tostring(f.what or f.title or ""))
    end
  end
  body[#body + 1] = ""
  body[#body + 1] = string.format("Open PR pushes %s and opens it%s on %s with the plan attached. Needs changes sends your words to the builder.",
    e.branch, config.load().pr.draft and " as a draft" or "", e.repo)
  return subject, table.concat(body, "\n")
end

local function enter_open_gate(e, session, ctx, check)
  e.phase = "open_gate"
  if config.load().gates.open == "auto" then
    e.phase = "opening"
    return
  end
  local subject, body = open_message(e, check)
  M.ask(e, "open", "gate", subject, body, GATES.open, ctx)
end

local function enter_preview_gate(e, ctx)
  local p = util.decode(util.read_file(tmp(e, "preview.json"))) or {}
  e.phase = "preview_gate"
  local title = p.title or ("Preview of " .. ledger.label(e))
  local ask = p.ask or "Does this look right?"
  local subject = decisions.cut(string.format("%s · preview · %s", ledger.label(e), title), 140)
  local a = M.ask(e, "preview", "gate", subject, ask .. (p.what and ("\n\n" .. p.what) or ""), GATES.preview, nil)
  if ctx and ctx.inbox and p.port then
    local ok, id, url = pcall(inbox.share, p.port, subject, ask, GATES.preview)
    if ok then
      a.message_id = id
      a.url = url
      e.preview_port = p.port
      ledger.remember_thread(id, { task = e.id, what = "preview", version = a.version })
      return
    end
    a.share_error = tostring(id)
  end
  if p.port then
    a.body = a.body .. string.format("\n\nIt's served at http://127.0.0.1:%d/ on this Mac.", p.port)
  end
  M.send_ask(e, a, ctx)
end

-- After a check: fix, or on to the gates.
local function after_check(e, session, ctx, check)
  local c = config.load()
  e.last_checked_head = e.built_head
  e.checked_head = e.built_head
  e.last_check = { n = e.check_n, verdict = check.verdict, findings = check.findings, summary = check.summary }
  if check.verdict == "fix" and #check.findings > 0 and (e.fix_loops_used or 0) < c.fix_loops then
    e.fix_loops_used = (e.fix_loops_used or 0) + 1
    e.phase = "building"
    send_builder(e, session, string.format("The checker found problems: .tmp/check/check-%d.json (and its report, .tmp/check/report-%d.md). Fix each one, or say in the report why it stands. Commit, update .tmp/pr.json if it changes, and write BUILT. This is fix round %d of %d.",
      e.check_n, e.check_n, e.fix_loops_used, c.fix_loops), "WORKING on fixes")
    ledger.append_event({ kind = "fixing", task = e.key, note = #check.findings .. " findings" })
    return
  end
  if has_outbox(e) then
    e.phase = "building"
    flush_outbox(e, session)
    return
  end
  local preview = util.exists(tmp(e, "preview.json"))
  if preview and c.gates.preview == "ask" and e.previewed_head ~= e.checked_head then
    enter_preview_gate(e, ctx)
  else
    enter_open_gate(e, session, ctx, check)
  end
end

-- Push the branch and open the PR, with the plan and the footer.
function M.open_pr(e, ctx)
  local c = config.load()
  local tracker = trackers.get(e.tracker)
  if e.branch == e.base then
    error("the task's branch is its base; nothing was pushed", 0)
  end
  local now = head(e)
  if now ~= e.checked_head then
    error(string.format("the branch moved to %s after the check passed %s; it's checked again before it opens", util.short(now), util.short(e.checked_head)), 0)
  end
  local bad = tmp_paths_in_diff(e)
  if #bad > 0 then
    error("the commits include .tmp/ files; nothing was pushed", 0)
  end
  local pr = read_pr(e)
  if not pr then
    error(".tmp/pr.json has no title and body; nothing was pushed", 0)
  end
  -- Someone else's commits on the remote branch would be lost: only a
  -- fast-forward goes.
  local remote = util.trim(git(e, { "ls-remote", "--heads", "origin", e.branch }).stdout):match("^(%x+)")
  if remote and not git(e, { "merge-base", "--is-ancestor", remote, "HEAD" }, { check = false }).ok then
    error(string.format("origin's %s has commits this branch doesn't; nothing was pushed", e.branch), 0)
  end
  git(e, { "push", "--quiet", "origin", "HEAD:refs/heads/" .. e.branch })
  e.pushed_head = now

  local login = ctx and ctx.login or e.login or github.login()
  local body = plan.strip(pr.body):gsub("%s+$", "")
  local closes = tracker.closes(e)
  if not body:find(closes, 1, true) then
    body = closes .. "\n\n" .. body
  end
  if e.plan_mode ~= false then
    local block = plan.block({
      key = e.key, login = login, mode = e.plan_mode or "full",
      plan = e.plan_text or util.read_file(tmp(e, "plan.md")) or "",
      decisions = e.decisions, approved_by = e.plan_approved_by, changes = e.plan_changes,
    })
    body = body .. "\n\n" .. block
  end
  local footer = string.format('---\n\n<div align="right"><sub><i>%s on behalf of @%s · checked by %s · <a href="https://github.com/captjt/rex-develop">rex-develop</a></i></sub></div>',
    agents.name(e, "builder"), login, agents.name(e, "checker"))
  body = body .. "\n\n" .. footer .. "\n"

  local existing = github.pr_for_branch(e.repo, e.branch)
  local made = existing or github.create_pr({
    repo = e.repo, base = e.base, head = e.branch, title = pr.title, body = body,
    draft = c.pr.draft, reviewers = c.pr.reviewers, cwd = e.worktree,
  })
  e.pr = { number = made.number, url = made.url, opened_at = util.now() }
  util.write_file(tmp(e, "pr-body.md"), body)
  return e.pr
end

-- One step for an active task. Returns nothing; adds to attention.
function M.advance(e, session, ctx, attention)
  local c = config.load()
  session = e.session_id or session
  local label = ledger.label(e)

  -- A prompt that didn't go in last step.
  if e.pending_prompt then
    local st = M.pane_state(session, e.pane)
    if st and st ~= "working" and st ~= "blocked" and M.prompt(session, e.pane, e.pending_prompt) then
      e.pending_prompt = nil
    end
  end

  -- The issue changed under a task that's working.
  if e.issue_changed and not (e.asks and e.asks.issue_changed) then
    M.ask(e, "issue_changed", "gate", decisions.cut(string.format("%s · %s", label, e.issue_changed), 140),
      string.format("%s: %s. The task is %s. Stop discards its worktree (its branch stays); Keep going carries on.", label, e.issue_changed, e.phase or e.state),
      GATES.issue_changed, ctx)
  end
  if e.state ~= "active" then
    return
  end

  -- New comments on the issue: fresh context for the builder.
  if e.new_comments and (e.phase == "planning" or e.phase == "building") then
    local ok = pcall(function()
      local info = trackers.get(e.tracker).context(e, tmp(e, "context"))
      e.comments_seen = info.comments or e.comments_seen
    end)
    if ok then
      queue_prompt(e, string.format("The issue has %d new comment%s; .tmp/context/issue.md has them. Check they don't change the plan; if one does, raise a decision.",
        e.new_comments, e.new_comments == 1 and "" or "s"))
      e.new_comments = nil
    end
  end

  scan_decisions(e, ctx)
  for _, a in pairs(e.asks or {}) do
    M.send_ask(e, a, ctx)
  end

  local st = M.status(e, "builder")
  local pane = M.pane_state(session, e.pane)
  local free = pane and pane ~= "working" and pane ~= "blocked"
  if not pane and (e.phase == "planning" or e.phase == "building") then
    needs(attention, e, "blocked", "the builder's pane closed mid-task; rex-develop focus " .. label .. " shows where it was")
    return
  end
  if pane == "blocked" then
    needs(attention, e, "blocked", "the builder is waiting on a prompt in its pane", "builder-prompt")
  end
  if st:match("^BLOCKED") and free then
    needs(attention, e, "blocked", "the builder stopped: " .. st:gsub("^BLOCKED:?%s*", ""), "builder")
  end

  if e.phase == "planning" then
    local parked = st:match("^DECISION%s+(D%d+)")
    if parked and free and has_outbox(e) then
      flush_outbox(e, session, "Your decision has an answer:", "Carry on with the plan, and write PLAN_READY when it's done.")
    elseif st == "PLAN_READY" and free then
      if has_outbox(e) then
        flush_outbox(e, session, "Before the plan goes out:", "Update .tmp/plan.md if these change it, then write PLAN_READY again.")
        return
      end
      local md = util.read_file(tmp(e, "plan.md"))
      local problems = plan.problems(md)
      if #problems > 0 then
        send_builder(e, session, ".tmp/plan.md isn't ready: " .. table.concat(problems, "; ") .. ". Fix it as .tmp/tasks/plan.md says, then write PLAN_READY.", "WORKING planning")
        return
      end
      e.plan_text = md
      e.plan_version = (e.plan_version or 0) + 1
      e.phase = "plan_gate"
      ledger.append_event({ kind = "planned", task = e.key, note = "version " .. e.plan_version })
      if c.gates.plan == "auto" then
        approve_plan(e, session, nil)
      else
        local subject, body = plan_message(e, md)
        M.ask(e, "plan", "gate", subject, body, GATES.plan, ctx)
      end
    elseif st:match("^NOT_READY") and free then
      local why = util.trim(st:gsub("^NOT_READY:?%s*", ""))
      local more = util.read_file(tmp(e, "not-ready.md"))
      e.phase = "not_ready"
      M.ask(e, "not_ready", "gate", decisions.cut(string.format("%s · not ready: %s", label, why), 140),
        (more or why) .. "\n\nProceed has the builder plan on its stated assumptions (add anything it should know). Drop stops the task; you'd fix the issue first.",
        GATES.not_ready, ctx)
    end
  elseif e.phase == "building" then
    -- Answers and notes go in whenever the builder is free: parked on a
    -- decision, or done. A BUILT that comes with news isn't final yet.
    if free and has_outbox(e) then
      flush_outbox(e, session)
      return
    end
    if st == "BUILT" and free and not e.pending_prompt then
      local problem = built_problem(e)
      if problem then
        if e.built_problem ~= problem then
          e.built_problem = problem
          send_builder(e, session, "Not ready for the check: " .. problem, "WORKING")
        end
        return
      end
      e.built_problem = nil
      start_check(e, session, ctx)
    end
  elseif e.phase == "checking" then
    local cst = M.status(e, "checker")
    local cpane = M.pane_state(session, e.checker_pane)
    if not cpane and cst:match("^CHECKING") then
      needs(attention, e, "blocked", "the checker's pane closed before it finished", "checker")
    elseif cst:match("^BLOCKED") and cpane ~= "working" then
      needs(attention, e, "blocked", "the checker stopped: " .. cst:gsub("^BLOCKED:?%s*", ""), "checker")
    elseif cst == "CHECKED" and cpane ~= "working" then
      local check = read_check(e)
      if not check then
        needs(attention, e, "blocked", string.format("the checker wrote CHECKED but no .tmp/check/check-%d.json", e.check_n), "checker")
        return
      end
      if head(e) ~= e.built_head then
        start_check(e, session, ctx)
        return
      end
      ledger.append_event({ kind = "checked", task = e.key, note = string.format("check %d: %s, %d findings", e.check_n, tostring(check.verdict), #check.findings) })
      after_check(e, session, ctx, check)
    end
  elseif e.phase == "open_gate" and not (e.asks and e.asks.open) then
    -- Here from the preview, or from a check: the PR's ask goes out.
    enter_open_gate(e, session, ctx, e.last_check)
  elseif e.phase == "opening" then
    local ok, res = pcall(M.open_pr, e, ctx)
    if ok then
      e.state = "open"
      e.phase = nil
      e.open_error = nil
      M.close_pane(session, e.checker_pane)
      M.close_pane(session, e.pane)
      ledger.append_event({ kind = "opened", task = e.key, note = res.url })
      tell(e, decisions.cut(string.format("%s · opened %s#%d", label, select(2, util.split_slug(e.repo)) or e.repo, res.number), 140),
        string.format("%s\n\n%s", e.title or "", res.url), ctx)
    else
      e.open_error = tostring(res)
      needs(attention, e, "error", "opening the PR failed: " .. e.open_error, "opening")
      if tostring(res):find("checked again", 1, true) then
        e.phase = "building"
        M.set_status(e, "builder", "BUILT")
      else
        e.phase = "open_gate"
        local subject, body = open_message(e, nil)
        M.ask(e, "open", "gate", subject, "Opening it failed: " .. e.open_error .. "\n\n" .. body, GATES.open, ctx)
      end
    end
  end
end

-- A task waiting to start: offer it, ask for its repo, or say it's queued.
function M.advance_waiting(e, ctx)
  local label = ledger.label(e)
  if e.state == "offered" and not (e.asks and e.asks.start) then
    M.ask(e, "start", "gate", decisions.cut(string.format("%s · in your cycle · %s", label, e.title or ""), 140),
      string.format("%s\n%s\n\nIt's assigned to you and in the active cycle. Start has an agent plan it; you approve the plan before any code is written. Skip leaves it to you. Not this cycle asks again next cycle.",
        e.title or "", e.url or ""),
      GATES.start, ctx)
  elseif e.state == "queued" and not e.repo and e.repo_choices and not (e.asks and e.asks.repo) then
    M.ask(e, "repo", "gate", decisions.cut(string.format("%s · which repo? · %s", label, e.title or ""), 140),
      string.format("%s\n%s\n\nIts team maps to more than one repo, and nothing on the issue picks one.", e.title or "", e.url or ""),
      e.repo_choices, ctx)
  end
  for _, a in pairs(e.asks or {}) do
    M.send_ask(e, a, ctx)
  end
end

-- A task whose PR is open: merged or closed ends it.
function M.advance_open(e, session)
  if not e.pr or not e.pr.number then
    return
  end
  local s = github.pr_state(e.repo, e.pr.number)
  if s == "MERGED" or s == "CLOSED" then
    M.close_pane(session, e.checker_pane)
    M.close_pane(session, e.pane)
    M.remove_worktree(e, s == "MERGED")
    e.state = s == "MERGED" and "merged" or "closed"
    e.ended_at = util.now()
    ledger.append_event({ kind = e.state, task = e.key, note = e.pr.url })
  end
end

-- Show a task's tab in Rex.
function M.focus(e)
  local session = e.session_id
  local _, block = M.pane_state(session, e.pane)
  if not block then
    return { shown = false, note = "its panes are closed" }
  end
  util.run({ "rex", "focus", "-s", session, block }, { check = false })
  return { shown = true, session = session, block = block }
end

return M
