-- Decision files, their messages, and reading replies: luajit tests/decisions.lua

local ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/tests/[^/]+$") or "."
package.path = ROOT .. "/lua/?.lua;" .. package.path
local t = dofile(ROOT .. "/tests/t.lua")
local d = require("rex_develop.decisions")

local good = {
  id = "D1",
  question = "Should retries cover 4xx responses?",
  why = "The issue says retry failed webhooks.",
  options = {
    { label = "5xx and timeouts only", detail = "Rejected payloads fail at once." },
    { label = "Every non-2xx", detail = "Simpler." },
  },
  recommend = 0,
  mode = "provisional",
  meanwhile = "Building with 5xx and timeouts only.",
}

local v, why = d.validate(good, "D1.json")
t.ok("a good decision validates", v)
t.eq("its mode", v.mode, "provisional")

local function bad(over, name)
  local x = {}
  for k, val in pairs(good) do
    x[k] = val
  end
  for k, val in pairs(over) do
    x[k] = val
  end
  local _, w = d.validate(x, name or "D1.json")
  return w
end
t.has("an id that isn't D<n>", bad({ id = "1" }), "id must be")
t.has("an id that isn't the file's", bad({ id = "D2" }), "the file is D1.json")
t.has("one option", bad({ options = { { label = "only" } } }), "give 2 to 5 options")
t.has("a label too long for a button", bad({ options = { { label = string.rep("x", 61) }, { label = "b" } } }), "longer than 60")
t.has("the same label twice", bad({ options = { { label = "A" }, { label = "a" } } }), "two options")
t.has("recommend out of range", bad({ recommend = 2 }), "recommend must be")
t.has("an unknown mode", bad({ mode = "soon" }), "mode must be")
t.eq("options may be plain strings", (d.validate({ id = "D1", question = "Q?", options = { "A", "B" }, recommend = 1 }, "D1.json")).options[2].label, "B")
t.eq("mode defaults to provisional", (d.validate({ id = "D1", question = "Q?", options = { "A", "B" }, recommend = 1 })).mode, "provisional")

-- The message.
local m = d.message("ENG-142", v)
t.eq("the subject names the task and the decision", m.subject, "ENG-142 · D1 · Should retries cover 4xx responses?")
t.has("the body marks the recommendation", m.body, "1. 5xx and timeouts only (recommended): Rejected payloads fail at once.")
t.has("and says what happens meanwhile", m.body, "Meanwhile: Building with 5xx and timeouts only.")
t.eq("the buttons are the labels", m.options, { "5xx and timeouts only", "Every non-2xx" })
local blocking = d.validate({ id = "D2", question = "Q?", options = { "A", "B" }, recommend = 0, mode = "blocking" })
t.has("a blocking decision says the builder waits", d.message("ENG-142", blocking).body, "waiting for this answer")

-- Replies.
local L = { "Approve", "Revise", "Discard" }
local function p(choice, body)
  return d.parse_reply(L, { choice = choice, body = body })
end
t.eq("a button", p("Approve", "Approve"), { choice = 1 })
t.eq("a button with words", p("Revise", "split the migration out"), { choice = 2, text = "split the migration out" })
t.eq("a button, any case", p("discard", ""), { choice = 3 })
t.eq("a number", p(nil, "2"), { choice = 2 })
t.eq("a number and a note", p(nil, "1, but drop the flag"), { choice = 1, text = "but drop the flag" })
t.eq("a number then but", p(nil, "1 but drop the flag"), { choice = 1, text = "but drop the flag" })
t.eq("a number out of range is words", p(nil, "7"), { text = "7" })
t.eq("a number that starts a sentence is words", p(nil, "3 attempts is plenty"), { text = "3 attempts is plenty" })
t.eq("a label typed out", p(nil, "approve"), { choice = 1 })
t.eq("a label with more", p(nil, "Revise: the plan misses the backfill"), { choice = 2, text = "the plan misses the backfill" })
t.eq("a word that only starts like a label isn't it", p(nil, "Approved by the team?"), { text = "Approved by the team?" })
t.eq("other words", p(nil, "Use a queue instead"), { text = "Use a queue instead" })
t.eq("nothing", p(nil, ""), {})
t.eq("the longest label wins", d.parse_reply({ "Open", "Open PR" }, { body = "open pr now" }), { choice = 2, text = "now" })

-- The record.
local ds = {
  D1 = { question = "Retry 4xx?", options = good.options, recommend = 0,
    answer = { choice = 0, label = "5xx and timeouts only", text = "and 429" } },
  D2 = { question = "Max attempts?", options = { { label = "5" }, { label = "10" } }, recommend = 0,
    answer = { choice = 0, label = "5", stood = true } },
  D10 = { question = "Later?", options = { { label = "A" }, { label = "B" } }, recommend = 1 },
}
local lines = d.lines(ds, "jo")
t.eq("decisions are listed by number", #lines, 3)
t.eq("an answered one says who chose", lines[1], '- **D1 · Retry 4xx?** 5xx and timeouts only. Chosen by @jo: "and 429".')
t.eq("one that stood says so", lines[2], "- **D2 · Max attempts?** 5. The recommendation stood; nobody answered.")
t.eq("D10 comes after D2", lines[3], "- **D10 · Later?** Open: not answered yet.")
t.eq("the builder hears an answer", d.answer_line("D1", ds.D1, ds.D1.answer), 'D1 (Retry 4xx?): 5xx and timeouts only, with this note: "and 429".')
t.eq("and its own words", d.answer_line("D3", { question = "Q?" }, { text = "use a queue" }), 'D3 (Q?): none of the options; the answer is: "use a queue".')

t.done("decisions")
