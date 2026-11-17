-- The intake rules. decide() is pure: it takes a task (or nil), one
-- observation of its issue from a tracker, and the start gates, and returns
-- the updated task and the events it produced. tests/rules.lua runs it on
-- made-up issue histories.
--
--   - Only an issue assigned to you, open for work (Todo), and either
--     labeled or in the active cycle starts a task.
--   - A labeled issue queues at once (gates.start.label = "auto"); a cycle
--     issue is offered first (gates.start.cycle = "ask").
--   - An issue that stops qualifying before work starts drops its task.
--     Once work has started, a canceled, finished, or reassigned issue
--     raises "issue changed" for you to answer.
--
-- An observation, as the tracker adapters give it:
--   { tracker, key, title, url, priority, labels, state_name,
--     mine, open_for_work, finished, label_match, skip, cycle_active,
--     cycle_id, comments, updated_at, ... }

local M = {}

-- States where no work has started: the task can simply be dropped.
local WAITING = { offered = true, queued = true, deferred = true, skipped = true }

function M.eligible(o)
  return o.mine and o.open_for_work and not o.skip and (o.label_match or o.cycle_active) and true or false
end

-- Why an issue doesn't qualify, for the event's note.
local function why_not(o)
  if o.finished then
    return "the issue is " .. (o.state_name or "closed")
  elseif not o.mine then
    return "the issue isn't assigned to you"
  elseif not o.open_for_work then
    return "the issue moved to " .. (o.state_name or "another state")
  elseif o.skip then
    return "the issue has the skip label"
  end
  return "the issue has no trigger label and isn't in the active cycle"
end

-- gates: config.gates.start, { label = "auto"|"ask", cycle = "auto"|"ask" }.
function M.decide(e, o, now, gates)
  gates = gates or { label = "auto", cycle = "ask" }
  local evs = {}
  local function emit(kind, note)
    evs[#evs + 1] = { kind = kind, task = o.key, note = note }
  end
  local eligible = M.eligible(o)
  local trigger = o.label_match and "label" or "cycle"

  local function enter(state_trigger)
    local gate = gates[state_trigger] or "ask"
    e.trigger = state_trigger
    e.state = gate == "auto" and "queued" or "offered"
    e.queued_at = e.state == "queued" and now or nil
    emit(e.state == "queued" and "queued" or "offered", state_trigger == "label" and "labeled" or "in the active cycle")
  end

  if not e then
    if not eligible then
      return nil, evs
    end
    e = { tracker = o.tracker, key = o.key, created_at = now, round = 0 }
    enter(trigger)
  elseif e.state == "dropped" and eligible then
    -- It qualifies again, such as a label put back.
    enter(trigger)
  elseif WAITING[e.state] then
    local manual = e.trigger == "manual"
    if o.finished or (not manual and not eligible) or (manual and not o.mine and not o.open_for_work) then
      e.state = "dropped"
      e.dropped_reason = why_not(o)
      emit("dropped", e.dropped_reason)
    elseif e.state == "offered" and o.label_match and gates.label == "auto" then
      -- Labeled while it waited to be offered: the label is the opt-in.
      enter("label")
    elseif e.state == "skipped" and o.label_match then
      enter("label")
    elseif e.state == "deferred" and (o.label_match or (o.cycle_id and o.cycle_id ~= e.deferred_cycle)) then
      enter(trigger)
    end
  elseif e.state == "active" then
    local reason
    if o.finished then
      reason = "the issue is " .. (o.state_name or "closed")
    elseif not o.mine then
      reason = "the issue isn't assigned to you any more"
    end
    if reason and e.issue_changed ~= reason and e.issue_changed_kept ~= reason then
      e.issue_changed = reason
      emit("issue-changed", reason)
    elseif not reason then
      e.issue_changed = nil
    end
    if (o.comments or 0) > (e.comments_seen or 0) then
      e.new_comments = (o.comments or 0) - (e.comments_seen or 0)
    end
  end

  e.title = o.title or e.title
  e.url = o.url or e.url
  e.priority = o.priority or e.priority
  e.labels = o.labels or e.labels
  e.issue_state = o.state_name or e.issue_state
  e.cycle_id = o.cycle_id
  e.issue_updated_at = o.updated_at or e.issue_updated_at
  e.comments_total = o.comments or e.comments_total
  if e.comments_seen == nil and e.state ~= "active" then
    e.comments_seen = o.comments or 0
  end
  return e, evs
end

-- Linear's priority: 1 urgent … 4 low, 0 none. None sorts last.
function M.priority_rank(p)
  p = tonumber(p) or 0
  return p == 0 and 5 or p
end

-- The queued tasks in the order they start: priority, then queue time.
function M.start_order(tasks)
  local q = {}
  for _, e in ipairs(tasks) do
    if e.state == "queued" then
      q[#q + 1] = e
    end
  end
  table.sort(q, function(a, b)
    local pa, pb = M.priority_rank(a.priority), M.priority_rank(b.priority)
    if pa ~= pb then
      return pa < pb
    end
    return (a.queued_at or a.created_at or "") < (b.queued_at or b.created_at or "")
  end)
  return q
end

return M
