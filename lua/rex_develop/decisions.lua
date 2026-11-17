-- Decisions and answers. An agent raises a decision by writing
-- .tmp/decisions/D<n>.json in its worktree; the watcher sends it to you,
-- and your answer lands beside it as D<n>.answer.json. docs/decisions.md
-- is the contract.
--
-- The same reply parsing serves the gates (plan, open, …): a gate is a
-- question with fixed options.
--
-- Everything here but the file helpers is pure, for tests/decisions.lua.

local util = require("rex_develop.util")

local M = {}

M.MAX_OPTIONS = 5
M.MAX_LABEL = 60
M.MODES = { provisional = true, blocking = true }

-- Check a decision file's content. Returns the decision, cleaned, or nil
-- and what's wrong with it, said so the agent can fix it.
function M.validate(d, filename)
  if type(d) ~= "table" then
    return nil, "it isn't a JSON object"
  end
  local want_id = filename and filename:match("^(D%d+)%.json$")
  if type(d.id) ~= "string" or not d.id:match("^D%d+$") then
    return nil, 'id must be "D" and a number, such as "D1"'
  end
  if want_id and d.id ~= want_id then
    return nil, string.format("its id is %s but the file is %s", d.id, filename)
  end
  if type(d.question) ~= "string" or util.trim(d.question) == "" then
    return nil, "question is missing"
  end
  local options = util.list(d.options)
  if #options < 2 or #options > M.MAX_OPTIONS then
    return nil, string.format("give 2 to %d options", M.MAX_OPTIONS)
  end
  local labels, seen = {}, {}
  for i, o in ipairs(options) do
    if type(o) == "string" then
      o = { label = o }
    end
    if type(o) ~= "table" or type(o.label) ~= "string" or util.trim(o.label) == "" then
      return nil, string.format("option %d needs a label", i)
    end
    local label = util.trim(o.label)
    if #label > M.MAX_LABEL then
      return nil, string.format("option %d's label is longer than %d characters; it's a button, so keep it short and put the rest in detail", i, M.MAX_LABEL)
    end
    if seen[label:lower()] then
      return nil, string.format("two options are labeled %q", label)
    end
    seen[label:lower()] = true
    labels[i] = { label = label, detail = type(o.detail) == "string" and util.trim(o.detail) or nil }
  end
  local rec = d.recommend
  if type(rec) ~= "number" or rec ~= math.floor(rec) or rec < 0 or rec >= #labels then
    return nil, string.format("recommend must be the index of an option, 0 to %d", #labels - 1)
  end
  local mode = d.mode or "provisional"
  if not M.MODES[mode] then
    return nil, 'mode must be "provisional" or "blocking"'
  end
  return {
    id = d.id,
    question = util.trim(d.question),
    why = type(d.why) == "string" and util.trim(d.why) or nil,
    options = labels,
    recommend = rec,
    mode = mode,
    meanwhile = type(d.meanwhile) == "string" and util.trim(d.meanwhile) or nil,
  }
end

-- The decision files in a worktree that have no answer yet, as
-- { name = "D1.json", id = "D1" }, in order of their numbers.
function M.pending_files(wt)
  local dir = wt .. "/.tmp/decisions"
  local out = {}
  for _, name in ipairs(util.list_dir(dir, "^D%d+%.json$")) do
    local id = name:match("^(D%d+)")
    if not util.exists(dir .. "/" .. id .. ".answer.json") then
      out[#out + 1] = { name = name, id = id, path = dir .. "/" .. name }
    end
  end
  table.sort(out, function(a, b)
    return tonumber(a.id:sub(2)) < tonumber(b.id:sub(2))
  end)
  return out
end

function M.write_answer(wt, id, answer)
  local dir = wt .. "/.tmp/decisions"
  util.mkdirp(dir)
  util.write_file(dir .. "/" .. id .. ".answer.json", util.json(answer) .. "\n")
end

---------------------------------------------------------------------------
-- Messages

local function cut(s, n)
  s = tostring(s or "")
  if #s <= n then
    return s
  end
  return s:sub(1, n - 1):gsub("[\128-\191]+$", ""):gsub("[\192-\255]$", "") .. "…"
end
M.cut = cut

-- The message for a decision: { subject, body, options }.
function M.message(label, d)
  local lines = {}
  if d.why then
    lines[#lines + 1] = d.why
    lines[#lines + 1] = ""
  end
  for i, o in ipairs(d.options) do
    local head = string.format("%d. %s%s", i, o.label, (i - 1) == d.recommend and " (recommended)" or "")
    lines[#lines + 1] = o.detail and (head .. ": " .. o.detail) or head
  end
  lines[#lines + 1] = ""
  if d.mode == "blocking" then
    lines[#lines + 1] = "The builder is waiting for this answer."
  elseif d.meanwhile then
    lines[#lines + 1] = "Meanwhile: " .. d.meanwhile
  else
    lines[#lines + 1] = "Meanwhile: the builder goes on with the recommendation."
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Answer with a button, a number, or your own words."
  local options = {}
  for i, o in ipairs(d.options) do
    options[i] = o.label
  end
  return {
    subject = cut(string.format("%s · %s · %s", label, d.id, d.question), 140),
    body = table.concat(lines, "\n"),
    options = options,
  }
end

---------------------------------------------------------------------------
-- Replies

local function lower(s)
  return tostring(s or ""):lower()
end

-- What a reply chose among labels: { choice = index (1-based) or nil,
-- text = the rest, or nil }. A reply carries the button pressed as
-- choice, its text as body, or both; text alone can be "2", "2, but cap it
-- at 3", or an option's label with or without more.
function M.parse_reply(labels, reply)
  local body = util.trim(reply.body or "")
  if reply.choice and reply.choice ~= "" then
    for i, l in ipairs(labels) do
      if lower(l) == lower(reply.choice) then
        local text = body
        if lower(text) == lower(l) then
          text = ""
        end
        return { choice = i, text = text ~= "" and text or nil }
      end
    end
  end
  if body == "" then
    return { choice = nil, text = nil }
  end
  -- A number alone, or followed by punctuation or "but": "2", "2.",
  -- "2, but cap it at 3". "3 attempts" is words, not option 3.
  local n, rest = body:match("^(%d+)%s*$"), ""
  if not n then
    n, rest = body:match("^(%d+)%s*[%.%):,;-]%s*(.*)$")
  end
  if not n then
    n, rest = body:match("^(%d+)%s+(but%s.*)$")
  end
  n = tonumber(n)
  if n and n >= 1 and n <= #labels then
    rest = util.trim(rest or "")
    return { choice = n, text = rest ~= "" and rest or nil }
  end
  -- The longest label the reply starts with, so "Open PR" beats "Open".
  local best, best_len
  for i, l in ipairs(labels) do
    local ll = lower(l)
    if lower(body):sub(1, #ll) == ll then
      local after = body:sub(#ll + 1, #ll + 1)
      if after == "" or not after:match("[%w]") then
        if not best_len or #ll > best_len then
          best, best_len = i, #ll
        end
      end
    end
  end
  if best then
    local rest2 = util.trim((body:sub(best_len + 1):gsub("^%s*[%.:,;-]+", "")))
    return { choice = best, text = rest2 ~= "" and rest2 or nil }
  end
  return { choice = nil, text = body }
end

---------------------------------------------------------------------------
-- The record, for the plan block and the prompts

-- One line per decision, for the plan block: what was decided, and by
-- whom. ds is the task's decisions table (by id), login the person's.
function M.lines(ds, login)
  local ids = {}
  for id in pairs(ds or {}) do
    ids[#ids + 1] = id
  end
  table.sort(ids, function(a, b)
    return tonumber(a:sub(2)) < tonumber(b:sub(2))
  end)
  local out = {}
  for _, id in ipairs(ids) do
    local d = ds[id]
    local a = d.answer
    local line
    if not a then
      line = string.format("- **%s · %s** Open: not answered yet.", id, d.question)
    else
      local what = a.label or "Another answer"
      if a.stood then
        line = string.format("- **%s · %s** %s. The recommendation stood; nobody answered.", id, d.question, what)
      else
        line = string.format("- **%s · %s** %s. Chosen by @%s%s.", id, d.question, what, login or "you",
          a.text and (': "' .. cut(a.text, 300):gsub("\n", " ") .. '"') or "")
      end
    end
    out[#out + 1] = line
  end
  return out
end

-- What an answer tells the agent, in one line.
function M.answer_line(id, d, a)
  if a.stood then
    return string.format("%s (%s): the recommendation stands: %s.", id, d.question, a.label)
  end
  if a.choice then
    return string.format("%s (%s): %s%s.", id, d.question, a.label, a.text and (', with this note: "' .. a.text .. '"') or "")
  end
  return string.format('%s (%s): none of the options; the answer is: "%s".', id, d.question, a.text or "")
end

return M
