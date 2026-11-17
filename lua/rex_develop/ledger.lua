-- The ledger: plain files under ~/.local/state/rex-develop that the
-- watcher, the actions, and the CLI read. docs/ledger.md is the contract.
--
--   state.json          switches, the last check, and the message threads
--   watcher.json        the watcher's last step: what needs you
--   events.jsonl        every event, one JSON object a line
--   check-now           left by a client: check the trackers now
--   answers/*.json      answers left by the actions, for the watcher
--   tasks/<id>.json     one entry per task (an issue rex-develop took on)

local util = require("rex_develop.util")
local config = require("rex_develop.config")

local M = {}

M.SCHEMA = 1

-- Task states. Only these hold a worktree.
M.ACTIVE = { active = true, open = true }
-- States a task never leaves.
M.TERMINAL = { dropped = true, discarded = true, merged = true, closed = true, cleaned = true }

local function dir()
  return config.STATE_DIR
end

function M.dir()
  return dir()
end

function M.check_now_path()
  return dir() .. "/check-now"
end

-- A task's id, from its tracker and key: linear-ENG-142, or
-- github-acme-api-45 for acme/api#45. Safe as a file name.
function M.task_id(tracker, key)
  return (tracker .. "-" .. tostring(key)):gsub("[^%w_.-]", "-")
end

function M.path(id)
  return string.format("%s/tasks/%s.json", dir(), id)
end

function M.load(id)
  return util.decode(util.read_file(M.path(id)))
end

function M.save(e)
  util.mkdirp(dir() .. "/tasks")
  e.updated_at = util.now()
  util.write_file(M.path(e.id), util.json(e) .. "\n")
end

-- Every task, oldest first.
function M.list()
  local out = {}
  for _, name in ipairs(util.list_dir(dir() .. "/tasks", "%.json$")) do
    local e = M.load(name:gsub("%.json$", ""))
    if e then
      out[#out + 1] = e
    end
  end
  table.sort(out, function(a, b)
    return (a.created_at or "") < (b.created_at or "")
  end)
  return out
end

-- The task a key names, such as ENG-142 or acme/api#45, or a task id.
function M.find(key)
  key = tostring(key or "")
  for _, e in ipairs(M.list()) do
    if e.id == key or e.key == key or (e.key or ""):lower() == key:lower() then
      return e
    end
  end
end

-- "ENG-142", or "api#45": for logs and messages.
function M.label(e)
  if e.tracker == "github" then
    local _, name = util.split_slug(e.repo or "")
    return string.format("%s#%s", name or "?", tostring(e.number or "?"))
  end
  return tostring(e.key)
end

function M.load_state()
  return util.decode(util.read_file(dir() .. "/state.json")) or { seq = 0 }
end

function M.save_state(st)
  util.mkdirp(dir())
  st.schema = M.SCHEMA
  util.write_file(dir() .. "/state.json", util.json(st) .. "\n")
end

function M.update_state(fn)
  local st = M.load_state()
  fn(st)
  M.save_state(st)
  return st
end

function M.append_event(ev)
  util.mkdirp(dir())
  local st = M.load_state()
  st.seq = (st.seq or 0) + 1
  ev.seq = st.seq
  ev.at = ev.at or util.now()
  util.append_file(dir() .. "/events.jsonl", util.json(ev) .. "\n")
  M.save_state(st)
  return ev
end

function M.events(filter)
  local out = {}
  for line in (util.read_file(dir() .. "/events.jsonl") or ""):gmatch("[^\n]+") do
    local ev = util.decode(line)
    if ev and (not filter or filter(ev)) then
      out[#out + 1] = ev
    end
  end
  return out
end

function M.save_watcher(info)
  util.mkdirp(dir())
  info.at = util.now()
  info.schema = M.SCHEMA
  util.write_file(dir() .. "/watcher.json", util.json(info) .. "\n")
end

function M.load_watcher()
  return util.decode(util.read_file(dir() .. "/watcher.json"))
end

function M.paused()
  return M.load_state().paused == true
end

function M.set_paused(v)
  M.update_state(function(st)
    st.paused = v or nil
  end)
  M.append_event({ kind = v and "paused" or "resumed" })
  return { paused = v }
end

---------------------------------------------------------------------------
-- Message threads: which task and item a rex-inbox message stands for, so
-- a reply finds its way back.

function M.remember_thread(message_id, ref)
  M.update_state(function(st)
    st.threads = type(st.threads) == "table" and st.threads or {}
    st.threads[tostring(message_id)] = ref
  end)
end

function M.thread(message_id)
  local st = M.load_state()
  return type(st.threads) == "table" and st.threads[tostring(message_id)] or nil
end

---------------------------------------------------------------------------
-- Answers the actions leave for the watcher. An action never changes a task
-- itself, so it can't race the watcher's own writes.

function M.queue_answer(a)
  local d = dir() .. "/answers"
  util.mkdirp(d)
  a.at = a.at or util.now()
  local name = string.format("%s-%d-%04d.json", os.date("!%Y%m%dT%H%M%S"), os.time(), math.random(0, 9999))
  util.write_file(d .. "/" .. name, util.json(a) .. "\n")
  util.write_file(M.check_now_path(), "")
  return name
end

-- The queued answers, oldest first, each removed as it's taken.
function M.take_answers()
  local d = dir() .. "/answers"
  local out = {}
  for _, name in ipairs(util.list_dir(d, "%.json$")) do
    local a = util.decode(util.read_file(d .. "/" .. name))
    os.remove(d .. "/" .. name)
    if a then
      out[#out + 1] = a
    end
  end
  return out
end

function M.format_event(ev)
  local t = ((ev.at or ""):match("T(%d%d:%d%d:%d%d)") or "") .. "Z"
  local bits = { t, string.format("%-14s", ev.task or ""), string.format("%-14s", ev.kind) }
  if ev.round then
    bits[#bits + 1] = "round " .. ev.round
  end
  if ev.note then
    bits[#bits + 1] = ev.note
  end
  return table.concat(bits, "  ")
end

return M
