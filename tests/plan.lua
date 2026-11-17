-- The plan and its block on the PR: luajit tests/plan.lua

local ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/tests/[^/]+$") or "."
package.path = ROOT .. "/lua/?.lua;" .. package.path
local t = dofile(ROOT .. "/tests/t.lua")
local plan = require("rex_develop.plan")

local md = [[
# Plan: ENG-142 Retry failed webhook deliveries

## Intent
Failed webhook deliveries retry with backoff, so a receiver's short outage no longer drops events.

## Acceptance
- A 5xx or a timeout retries up to 5 times, with backoff: `retry::backs_off`.
- Each attempt is logged: `retry::logs_attempts`.

## Decisions
- D1: Retry 4xx? Recommended: no.

## Approach
1. Wrap `deliver` in a retry loop.

## Out of scope
- A dead-letter queue (ENG-150).

## Notes
- Backoff doubles from 1 s; that's the codebase's convention.
]]

local s = plan.sections(md)
t.eq("six sections", #s, 6)
t.eq("in order", s[2].title, "Acceptance")
t.has("a section's body", plan.section(md, "acceptance"), "retry::logs_attempts")
t.eq("a good plan has no problems", plan.problems(md), {})
t.has("an empty plan", plan.problems("")[1], "empty")
t.has("no Intent", plan.problems("## Acceptance\n- a\n")[1], '"## Intent"')
t.has("acceptance that isn't a list", plan.problems("## Intent\nx\n## Acceptance\nIt works.\n")[1], "should be a list")

local ds = {
  D1 = { question = "Retry 4xx?", options = { { label = "No" }, { label = "Yes" } }, recommend = 0,
    answer = { choice = 0, label = "No" } },
}
local block = plan.block({ key = "ENG-142", login = "jo", mode = "full", plan = md, decisions = ds, approved_by = "jo",
  changes = { "Round 2: 429 retries too." } })
t.has("it starts with the marker", block, "<!-- rex-develop:plan v1 ENG-142 -->")
t.has("it says who approved it", block, "<b>Plan</b> · ENG-142 · approved by @jo")
t.has("a one-line intent runs in", block, "**Intent.** Failed webhook deliveries retry")
t.has("acceptance as written", block, "- Each attempt is logged: `retry::logs_attempts`.")
t.has("decisions from the record, not the plan", block, "- **D1 · Retry 4xx?** No. Chosen by @jo.")
t.eq("the builder's own Decisions list stays out", block:find("Recommended: no", 1, true), nil)
t.eq("Approach stays out", block:find("Wrap `deliver`", 1, true), nil)
t.has("out of scope", block, "A dead-letter queue (ENG-150)")
t.has("notes, in full mode", block, "Backoff doubles")
t.has("changes since", block, "- Round 2: 429 retries too.")
t.has("it ends with the end marker", block, "</details>\n<!-- /rex-develop:plan -->")
local i_dec, i_out = block:find("**Decisions**", 1, true), block:find("**Out of scope**", 1, true)
t.ok("decisions come before out of scope", i_dec and i_out and i_dec < i_out)

local summary = plan.block({ key = "ENG-142", login = "jo", mode = "summary", plan = md, decisions = ds })
t.eq("summary mode leaves Notes out", summary:find("Backoff doubles", 1, true), nil)
t.has("an automatic approval says so", summary, "approved automatically")

-- Putting it in a body, and taking it out.
local body = "Closes ENG-142\n\nWhy it changes."
local with = plan.place(body, block)
t.has("placed at the end", with, "Why it changes.\n\n<!-- rex-develop:plan v1")
t.eq("stripped again", plan.strip(with), body)
local footer = '\n\n---\n\n<div align="right"><sub><i>by an agent</i></sub></div>'
local placed = plan.place(body .. footer, block)
t.ok("placed before a footer", placed:find("<!-- /rex-develop:plan -->", 1, true) < placed:find("<div align=\"right\">", 1, true))
local newer = plan.block({ key = "ENG-142", login = "jo", mode = "full", plan = md, decisions = ds, changes = { "Round 3." } })
local replaced = plan.place(with, newer)
t.has("a new block replaces the old", replaced, "Round 3.")
t.eq("only one block", select(2, replaced:gsub("rex%-develop:plan v1", "")), 1)

t.done("plan")
