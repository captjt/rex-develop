-- The trackers: where tasks come from. Each is a module in this folder with
--
--   name                      "linear" or "github"
--   scan(tracked)             observations for the issues that qualify now and
--                             the tracked ones; see rules.lua for the fields
--   lookup(key)               one issue's observation, for `rex-develop start`
--   context(task, dir)        write issue.json and issue.md into dir
--   branch(task)              the branch the task builds on
--   closes(task)              the line in the PR body that links the issue
--
-- They only read. Nothing here writes to a tracker.

local config = require("rex_develop.config")

local M = {}
local loaded = {}

M.NAMES = { "linear", "github" }

function M.get(name)
  if not loaded[name] then
    loaded[name] = require("rex_develop.trackers." .. name)
  end
  return loaded[name]
end

-- The trackers the config turns on, in order.
function M.enabled()
  local c = config.load()
  local out = {}
  for _, name in ipairs(M.NAMES) do
    if c.trackers[name] then
      out[#out + 1] = M.get(name)
    end
  end
  return out
end

-- The tracker an issue key belongs to: owner/name#45 is GitHub, ENG-142 is
-- Linear.
function M.for_key(key)
  if tostring(key):find("#") or tostring(key):find("github%.com") then
    return M.get("github")
  end
  return M.get("linear")
end

return M
