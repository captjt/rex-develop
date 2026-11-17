-- The watcher's program status (OSC 7501): the record its pane reports, and
-- one child record for each item that needs you. Rex shows them on the
-- watcher's tab, and so does any tool that follows program status.
--
--   (root)                    the watcher: idle, or error when a scan or a step failed
--   task/<task>/<what>        a task's item: a gate (start, plan, open, …), a
--                             decision (D1, …), or a problem (blocked, error)
--
-- When rex-inbox is running, gates and decisions reach you as messages
-- instead, so only problems are reported here and nothing shows twice.
-- This module only builds strings, so it runs anywhere Lua does.

local M = {}

M.APP = "rex-develop"

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function M.b64(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local function at(shift)
      local k = math.floor(n / shift) % 64 + 1
      return B64:sub(k, k)
    end
    out[#out + 1] = at(262144) .. at(4096) .. (b and at(64) or "=") .. (c and at(1) or "=")
  end
  return table.concat(out)
end

-- One line of text, without control characters (the protocol refuses
-- them), cut to at most max bytes without splitting a UTF-8 character.
function M.line(s, max)
  s = tostring(s or ""):gsub("[%c]+", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if #s <= max then
    return s
  end
  local cut = max - 3
  while cut > 0 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do
    cut = cut - 1
  end
  return s:sub(1, cut) .. "..."
end

-- An id segment: the protocol allows [A-Za-z0-9_.+-], 1 to 32 of them.
function M.segment(s)
  s = tostring(s or ""):gsub("[^%w_.+-]", "-"):sub(1, 32)
  return s ~= "" and s or "-"
end

function M.item_id(task_id, what)
  return string.format("task/%s/%s", M.segment(task_id), M.segment(what))
end

-- The record for one attention item: { task, label, title, kind, what,
-- text }. kind "waiting" is a gate or decision (blocked, a question),
-- "blocked" an agent that stopped, and "error" a step that failed.
function M.record(a)
  local title = (type(a.title) == "string" and a.title ~= "") and (a.label .. " " .. a.title) or a.label
  local r = { id = M.item_id(a.task, a.what or a.kind), app = M.APP, title = M.line(title, 190) }
  if a.kind == "waiting" then
    r.state, r.kind = "blocked", "question"
  elseif a.kind == "blocked" then
    r.state = "blocked"
  else
    r.state = "error"
  end
  r.msg = M.line(a.text, 600)
  return r
end

-- The root record: idle while the watcher runs, error when a scan or a
-- step failed. health = { error = text?, paused = bool? }.
function M.root(health)
  health = health or {}
  if health.error then
    return { id = "", app = M.APP, state = "error", msg = M.line(health.error, 300) }
  end
  return { id = "", app = M.APP, state = "idle", msg = health.paused and "Paused" or nil }
end

-- The OSC 7501 report for a record.
function M.report(r)
  local fields = { "state=" .. r.state }
  if r.id and r.id ~= "" then
    fields[#fields + 1] = "id=" .. r.id
  end
  if r.kind then
    fields[#fields + 1] = "kind=" .. r.kind
  end
  if r.app then
    fields[#fields + 1] = "app=" .. r.app
  end
  if r.title and r.title ~= "" then
    fields[#fields + 1] = "title=" .. M.b64(r.title)
  end
  if r.msg and r.msg ~= "" then
    fields[#fields + 1] = "msg=" .. M.b64(r.msg)
  end
  return "\27]7501;" .. table.concat(fields, ":") .. "\27\\"
end

-- Clear every record on the pane, for a watcher that just started.
M.CLEAR_ALL = "\27]7501;state=clear\27\\"

-- The reports that take the pane from what shown says it last reported to
-- the root and the items given. shown maps id to report and is updated.
-- Items that left are cleared; unchanged ones aren't sent again.
function M.sync(shown, root, items)
  local out, want = {}, {}
  local records = { root }
  for _, a in ipairs(items or {}) do
    records[#records + 1] = M.record(a)
  end
  for _, r in ipairs(records) do
    local id = r.id or ""
    if not want[id] then
      local s = M.report(r)
      want[id] = s
      if shown[id] ~= s then
        out[#out + 1] = s
      end
    end
  end
  local gone = {}
  for id in pairs(shown) do
    if not want[id] then
      gone[#gone + 1] = id
    end
  end
  table.sort(gone)
  for _, id in ipairs(gone) do
    out[#out + 1] = "\27]7501;state=clear:id=" .. id .. "\27\\"
    shown[id] = nil
  end
  for id, s in pairs(want) do
    shown[id] = s
  end
  return out
end

return M
