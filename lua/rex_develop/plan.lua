-- The plan: the builder writes .tmp/plan.md in the sections of
-- guides/plan-format.md, you approve it, the checker holds the diff to it,
-- and it goes out with the PR as a block between markers, so reviewers
-- (people, and rex-reviewer) can check the change against what it set out
-- to do. Pure, for tests/plan.lua.

local decisions = require("rex_develop.decisions")

local M = {}

M.START = "<!-- rex-develop:plan v1"
M.END = "<!-- /rex-develop:plan -->"

-- The sections the plan must have, and the ones the PR's block carries.
M.REQUIRED = { "Intent", "Acceptance" }
local BLOCK_SECTIONS = {
  full = { "Intent", "Acceptance", "Out of scope", "Notes" },
  summary = { "Intent", "Acceptance", "Out of scope" },
}

-- The plan's sections, by their "## " headings, in order:
-- { { title = "Intent", body = "…" }, … }. The "# " title line and any
-- text before the first section are left out.
function M.sections(md)
  local out = {}
  local cur
  for line in (tostring(md or "") .. "\n"):gmatch("([^\n]*)\n") do
    local title = line:match("^##%s+(.-)%s*$")
    if title and not line:match("^###") then
      cur = { title = title, lines = {} }
      out[#out + 1] = cur
    elseif cur then
      cur.lines[#cur.lines + 1] = line
    end
  end
  for _, s in ipairs(out) do
    s.body = table.concat(s.lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    s.lines = nil
  end
  return out
end

function M.section(md, title)
  for _, s in ipairs(M.sections(md)) do
    if s.title:lower() == title:lower() then
      return s.body
    end
  end
end

-- What's wrong with a plan, as a list of sentences for the builder.
function M.problems(md)
  local out = {}
  if not md or md:match("^%s*$") then
    return { "plan.md is empty" }
  end
  for _, title in ipairs(M.REQUIRED) do
    local body = M.section(md, title)
    if not body or body == "" then
      out[#out + 1] = string.format('it needs a "## %s" section with something in it', title)
    end
  end
  local acc = M.section(md, "Acceptance") or ""
  if acc ~= "" and not acc:match("%-%s") and not acc:match("%d%.%s") then
    out[#out + 1] = "Acceptance should be a list: one item for each thing that must be true, with how it's shown"
  end
  return out
end

-- The block that goes on the PR. o = { key, login, mode ("full" or
-- "summary"), plan (plan.md), decisions (the task's, by id),
-- changes (a list of lines), approved_by (login, or nil when the plan
-- gate was auto) }.
function M.block(o)
  local out = {}
  local function add(s)
    out[#out + 1] = s
  end
  add(string.format("%s %s -->", M.START, o.key))
  local who = o.approved_by and ("approved by @" .. o.approved_by) or "approved automatically"
  add(string.format("<details open><summary><b>Plan</b> · %s · %s</summary>", o.key, who))
  add("")
  local mode = BLOCK_SECTIONS[o.mode] and o.mode or "full"
  local wrote_decisions = false
  local function add_decisions()
    local lines = decisions.lines(o.decisions, o.login)
    if #lines > 0 then
      add("**Decisions**")
      add("")
      for _, l in ipairs(lines) do
        add(l)
      end
      add("")
    end
    wrote_decisions = true
  end
  for _, title in ipairs(BLOCK_SECTIONS[mode]) do
    local body = M.section(o.plan, title)
    if title == "Out of scope" and not wrote_decisions then
      add_decisions()
    end
    if body and body ~= "" then
      if title == "Intent" and not body:find("\n") then
        add("**Intent.** " .. body)
      else
        add("**" .. title .. "**")
        add("")
        add(body)
      end
      add("")
    end
  end
  if not wrote_decisions then
    add_decisions()
  end
  if o.changes and #o.changes > 0 then
    add("**Changes since the plan**")
    add("")
    for _, c in ipairs(o.changes) do
      add("- " .. c)
    end
    add("")
  end
  add("</details>")
  add(M.END)
  return table.concat(out, "\n")
end

-- The body without a plan block.
function M.strip(body)
  body = tostring(body or "")
  local s = body:find(M.START, 1, true)
  if not s then
    return body
  end
  local e = body:find(M.END, s, true)
  if not e then
    return (body:sub(1, s - 1):gsub("%s+$", ""))
  end
  local before = body:sub(1, s - 1):gsub("%s+$", "")
  local after = body:sub(e + #M.END):gsub("^%s+", "")
  if after == "" then
    return before
  end
  return before .. "\n\n" .. after
end

-- The body with the block in place of any old one. A new block goes
-- before the footer when there is one (a "---" line then a <div>),
-- otherwise at the end.
function M.place(body, block)
  body = tostring(body or "")
  local s = body:find(M.START, 1, true)
  local e = s and body:find(M.END, s, true)
  if s and e then
    return body:sub(1, s - 1) .. block .. body:sub(e + #M.END)
  end
  local foot = body:find("\n%-%-%-\n+<div align=\"right\">")
  if foot then
    return body:sub(1, foot - 1):gsub("%s+$", "") .. "\n\n" .. block .. "\n" .. body:sub(foot)
  end
  body = body:gsub("%s+$", "")
  return (body ~= "" and (body .. "\n\n") or "") .. block
end

return M
