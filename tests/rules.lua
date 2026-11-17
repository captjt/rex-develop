-- The intake rules on made-up issue histories: luajit tests/rules.lua

local ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/tests/[^/]+$") or "."
package.path = ROOT .. "/lua/?.lua;" .. package.path
local t = dofile(ROOT .. "/tests/t.lua")
local rules = require("rex_develop.rules")

local GATES = { label = "auto", cycle = "ask" }
local NOW = "2026-11-17T12:00:00Z"

-- An observation of ENG-142, with changes.
local function obs(over)
  local o = {
    tracker = "linear", key = "ENG-142", title = "Retry failed webhooks", url = "https://linear.app/acme/issue/ENG-142",
    priority = 2, labels = {}, state_name = "Todo", mine = true, open_for_work = true, finished = false,
    label_match = false, skip = false, cycle_active = false, cycle_id = "cyc-1", comments = 0,
  }
  for k, v in pairs(over or {}) do
    o[k] = v
  end
  return o
end

local function kinds(evs)
  local out = {}
  for _, e in ipairs(evs) do
    out[#out + 1] = e.kind
  end
  return table.concat(out, ",")
end

-- Nothing qualifies: no task.
local e, evs = rules.decide(nil, obs(), NOW, GATES)
t.eq("an issue with no label, out of the cycle, is left alone", e, nil)
t.eq("and says nothing", #evs, 0)

e = rules.decide(nil, obs({ label_match = true, mine = false }), NOW, GATES)
t.eq("someone else's labeled issue is left alone", e, nil)

e = rules.decide(nil, obs({ label_match = true, open_for_work = false, state_name = "In Progress" }), NOW, GATES)
t.eq("an issue already in progress is left alone", e, nil)

e = rules.decide(nil, obs({ cycle_active = true, skip = true }), NOW, GATES)
t.eq("the skip label keeps a cycle issue out", e, nil)

-- A labeled issue queues at once.
e, evs = rules.decide(nil, obs({ label_match = true }), NOW, GATES)
t.eq("a labeled issue queues", e.state, "queued")
t.eq("its trigger is the label", e.trigger, "label")
t.eq("it says so", kinds(evs), "queued")

-- With the label gate on ask, it's offered instead.
e = rules.decide(nil, obs({ label_match = true }), NOW, { label = "ask", cycle = "ask" })
t.eq("with gates.start.label = ask, a labeled issue is offered", e.state, "offered")

-- A cycle issue is offered.
e, evs = rules.decide(nil, obs({ cycle_active = true }), NOW, GATES)
t.eq("a cycle issue is offered", e.state, "offered")
t.eq("its trigger is the cycle", e.trigger, "cycle")
t.eq("it says so", kinds(evs), "offered")

-- Labeled while it was offered: the label is the opt-in.
e = rules.decide(e, obs({ cycle_active = true, label_match = true }), NOW, GATES)
t.eq("an offered issue that gets the label queues", e.state, "queued")
t.eq("its trigger becomes the label", e.trigger, "label")

-- Leaving the cycle before it starts drops it.
e = rules.decide(nil, obs({ cycle_active = true }), NOW, GATES)
e, evs = rules.decide(e, obs({ cycle_active = false }), NOW, GATES)
t.eq("an offered issue out of the cycle is dropped", e.state, "dropped")
t.has("with why", e.dropped_reason, "active cycle")

-- Put back in, it comes back.
e = rules.decide(e, obs({ label_match = true }), NOW, GATES)
t.eq("a dropped issue that qualifies again queues", e.state, "queued")

-- Unassigned while queued: dropped.
e = rules.decide(e, obs({ label_match = true, mine = false }), NOW, GATES)
t.eq("a queued issue given to someone else is dropped", e.state, "dropped")
t.has("with why", e.dropped_reason, "isn't assigned to you")

-- Skipped stays skipped in the cycle, but the label overrides.
e = { tracker = "linear", key = "ENG-142", state = "skipped", trigger = "cycle", round = 0 }
e = rules.decide(e, obs({ cycle_active = true }), NOW, GATES)
t.eq("a skipped cycle issue stays skipped", e.state, "skipped")
e = rules.decide(e, obs({ cycle_active = true, label_match = true }), NOW, GATES)
t.eq("a skipped issue that gets the label queues", e.state, "queued")

-- Not this cycle: asked again next cycle.
e = { tracker = "linear", key = "ENG-142", state = "deferred", trigger = "cycle", deferred_cycle = "cyc-1", round = 0 }
e = rules.decide(e, obs({ cycle_active = true, cycle_id = "cyc-1" }), NOW, GATES)
t.eq("a deferred issue in the same cycle stays deferred", e.state, "deferred")
e = rules.decide(e, obs({ cycle_active = true, cycle_id = "cyc-2" }), NOW, GATES)
t.eq("in the next cycle it's offered again", e.state, "offered")

-- Work started: a canceled issue asks rather than drops.
e = { tracker = "linear", key = "ENG-142", state = "active", phase = "building", trigger = "label", round = 1, comments_seen = 0 }
e, evs = rules.decide(e, obs({ finished = true, open_for_work = false, state_name = "Canceled" }), NOW, GATES)
t.eq("a canceled issue under an active task stays active", e.state, "active")
t.eq("and raises issue-changed", e.issue_changed, "the issue is Canceled")
t.eq("once", kinds(evs), "issue-changed")
e, evs = rules.decide(e, obs({ finished = true, open_for_work = false, state_name = "Canceled" }), NOW, GATES)
t.eq("not again on the next scan", #evs, 0)

-- Kept going: the same change doesn't ask again.
e.issue_changed_kept, e.issue_changed = e.issue_changed, nil
e, evs = rules.decide(e, obs({ finished = true, open_for_work = false, state_name = "Canceled" }), NOW, GATES)
t.eq("after Keep going, the same change asks nothing", #evs, 0)

-- An active task moved to started (as Linear does when a branch is pushed)
-- is fine.
e = { tracker = "linear", key = "ENG-142", state = "active", phase = "building", trigger = "label", round = 1, comments_seen = 0 }
e, evs = rules.decide(e, obs({ open_for_work = false, state_name = "In Progress", label_match = true }), NOW, GATES)
t.eq("an active task whose issue moved to In Progress carries on", e.issue_changed, nil)

-- New comments.
e = rules.decide(e, obs({ open_for_work = false, comments = 2 }), NOW, GATES)
t.eq("new comments on an active task are counted", e.new_comments, 2)

-- A manual task survives losing the triggers, not being finished.
e = { tracker = "linear", key = "ENG-142", state = "queued", trigger = "manual", round = 0 }
e = rules.decide(e, obs({}), NOW, GATES)
t.eq("a task started by hand stays queued without a label", e.state, "queued")
e = rules.decide(e, obs({ finished = true, open_for_work = false, state_name = "Done" }), NOW, GATES)
t.eq("but is dropped when the issue is done", e.state, "dropped")

-- Start order: priority, then queue time; no priority last.
local order = rules.start_order({
  { key = "A", state = "queued", priority = 0, queued_at = "1" },
  { key = "B", state = "queued", priority = 3, queued_at = "2" },
  { key = "C", state = "queued", priority = 1, queued_at = "3" },
  { key = "D", state = "queued", priority = 3, queued_at = "1" },
  { key = "E", state = "offered", priority = 1 },
})
local keys = {}
for _, x in ipairs(order) do
  keys[#keys + 1] = x.key
end
t.eq("queued tasks start urgent first, then by queue time, unprioritized last", table.concat(keys, ","), "C,D,B,A")

t.done("rules")
