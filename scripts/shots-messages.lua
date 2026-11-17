-- The messages rex-develop would send in the made-up world of
-- scripts/screenshots.sh, made by rex-develop's own code, so the pictures
-- show what it really sends. Prints a JSON list, oldest first:
-- { subject, body, options, minutes } (minutes before now).
--
--   luajit scripts/shots-messages.lua

local SRC = debug.getinfo(1, "S").source:gsub("^@", "")
if SRC:sub(1, 1) ~= "/" then
  SRC = (os.getenv("PWD") or ".") .. "/" .. SRC
end
local ROOT = SRC:match("^(.*)/scripts/[^/]+$")
package.path = ROOT .. "/lua/?.lua;" .. package.path
require("rex_develop.config").set_root(ROOT)
local util = require("rex_develop.util")
local decisions = require("rex_develop.decisions")
local tasks = require("rex_develop.tasks")

local out = {}
local function add(subject, body, options, minutes)
  out[#out + 1] = { subject = subject, body = body, options = options, minutes = minutes }
end

-- ENG-131 opened its PR an hour ago.
local s, b = tasks.opened_message(
  { tracker = "linear", key = "ENG-131", title = "Rate-limit the export endpoint", repo = "acme/api" },
  { number = 341, url = "https://github.com/acme/api/pull/341" })
add(s, b, nil, 52)

-- ENG-150 is in the cycle, without the label: offered first.
s, b = tasks.start_message({ tracker = "linear", key = "ENG-150", title = "Dead-letter queue for failed webhooks",
  url = "https://linear.app/acme/issue/ENG-150" })
add(s, b, { "Start", "Skip", "Not this cycle" }, 24)

-- ENG-138's builder stopped on a decision it can't build around.
local d2 = decisions.validate({
  id = "D2",
  question = "Stream the export, or page it?",
  why = "The issue asks for exports of any size. Streaming keeps one request; paging changes the API's contract for every client.",
  options = {
    { label = "Stream NDJSON", detail = "One request, constant memory; clients read line by line." },
    { label = "Page with a cursor", detail = "Works with today's clients; big exports take many requests." },
  },
  recommend = 0,
  mode = "blocking",
}, "D2.json")
local m = decisions.message("ENG-138", d2)
add(m.subject, m.body, m.options, 11)

-- ENG-142: the plan, and the decision that came with it.
local d1 = decisions.validate({
  id = "D1",
  question = "Should retries cover 4xx responses?",
  why = "The issue says \"retry failed webhooks\". A 4xx usually means the receiver rejected the payload, so retrying it may flood them.",
  options = {
    { label = "5xx and timeouts only", detail = "Rejected payloads fail at once and show in the delivery log." },
    { label = "Every non-2xx", detail = "Simpler, but a bad payload is sent 5 times." },
  },
  recommend = 0,
  mode = "provisional",
  meanwhile = "Building with 5xx and timeouts only. Switching later is a one-line change.",
}, "D1.json")
m = decisions.message("ENG-142", d1)
add(m.subject, m.body, m.options, 3)

local plan_md = [[
# Plan: ENG-142 Retry failed webhook deliveries

## Intent
Webhook deliveries that fail retry with backoff, so a receiver's short outage no longer drops events.

## Acceptance
- A delivery that gets a 5xx or times out retries up to 5 times, with backoff: `webhooks::retry::backs_off`.
- Each attempt is logged with its status: `webhooks::retry::logs_attempts`.

## Decisions
- D1: Should retries cover 4xx responses? Recommended: 5xx and timeouts only.

## Approach
1. Wrap `deliver` in a retry loop with exponential backoff.
2. Log each attempt in `delivery_attempts`.

## Out of scope
- A dead-letter queue (ENG-150).
]]
local e = {
  tracker = "linear", key = "ENG-142", title = "Retry failed webhook deliveries", plan_version = 1,
  decisions = { D1 = { question = d1.question, options = d1.options, recommend = d1.recommend } },
}
s, b = tasks.plan_message(e, plan_md)
add(s, b, { "Approve", "Revise", "Discard" }, 2)

print(util.json(out))
