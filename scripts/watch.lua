-- The watcher, under LuaJIT, in the control tab of the rex-develop
-- session. `rex-develop up` runs it inside a loop that restarts it:
--
--   luajit <rex-develop>/scripts/watch.lua
--
-- Every 5 seconds it takes your answers and moves each task one step;
-- every poll_seconds, or when a client leaves check-now, it checks the
-- trackers first. It reports program status (OSC 7501) on its own pane:
-- its root record, and a record for each problem, and for each ask when
-- rex-inbox isn't carrying them. It spends no tokens.

local SRC = debug.getinfo(1, "S").source:gsub("^@", "")
if SRC:sub(1, 1) ~= "/" then
  SRC = (os.getenv("PWD") or ".") .. "/" .. SRC
end
local ROOT = SRC:match("^(.*)/scripts/[^/]+$")
package.path = ROOT .. "/lua/?.lua;" .. package.path
local config = require("rex_develop.config")
config.set_root(ROOT)
local util = require("rex_develop.util")
local ledger = require("rex_develop.ledger")
local status = require("rex_develop.status")
local watcher = require("rex_develop.watcher")

local TICK = 5

local function log(line)
  io.write(os.date("!%H:%M:%SZ"), "  ", line, "\n")
  io.flush()
end

local shown = {}
local function report(root, items)
  local out = status.sync(shown, root, items)
  if #out > 0 then
    io.write(table.concat(out))
    io.flush()
  end
end

local session = os.getenv("REX_SESSION")
local c = config.load(true)
local repos = {}
for _, r in ipairs(c.repo_list) do
  repos[#repos + 1] = r.slug
end
local tr = {}
for name in pairs(c.trackers) do
  tr[#tr + 1] = name
end
table.sort(tr)
log(string.format("rex-develop watcher: %s from %s; %s builds, %s checks; every %ds, up to %d tasks at once%s",
  table.concat(repos, ", "), table.concat(tr, " and "), c.builder.agent, c.checker.agent, c.poll_seconds, c.max_tasks,
  ledger.paused() and " (paused)" or ""))

-- A watcher before this one may have left records. Then the root record
-- goes first: rex-inbox counts a pane that reports a status as a tool of
-- its own, so the messages it sends come from it, not from you.
io.write(status.CLEAR_ALL)
report(status.root({ paused = ledger.paused() }), nil)

local last_scan = 0
while true do
  local scan = os.time() - last_scan >= c.poll_seconds or os.remove(ledger.check_now_path()) ~= nil
  if scan then
    last_scan = os.time()
  end
  local ok, err = pcall(function()
    local attention, waiting, scan_error, ctx = watcher.step(session, scan, log)
    c = config.load()
    local items = {}
    util.append(items, attention)
    -- Asks show here only when they couldn't reach you as a message.
    for _, w in ipairs(waiting) do
      if not w.message_id then
        items[#items + 1] = { task = w.task, label = w.label, title = w.title, kind = "waiting", what = w.what, text = w.subject }
      end
    end
    ledger.save_watcher({ attention = attention, waiting = waiting, scan_error = scan_error, inbox = ctx.inbox })
    report(status.root({ error = scan_error and ("scan failed: " .. scan_error) or nil, paused = ledger.paused() }), items)
  end)
  if not ok then
    log("step failed: " .. tostring(err))
    pcall(report, status.root({ error = "step failed: " .. tostring(err) }), nil)
    pcall(ledger.save_watcher, { attention = {}, waiting = {}, error = tostring(err):sub(1, 300) })
  end
  util.sleep(TICK)
end
