-- rex-develop's actions under LuaJIT. bin/rex-develop runs it:
--
--   luajit scripts/cli.lua <action> [key=value ...] [--json]
--   luajit scripts/cli.lua --list        the actions, one a line
--
-- A result prints as JSON. An error prints as "Error: <what>" on stderr and
-- exits 1, as `rex do` does.

local SRC = debug.getinfo(1, "S").source:gsub("^@", "")
if SRC:sub(1, 1) ~= "/" then
  SRC = (os.getenv("PWD") or ".") .. "/" .. SRC
end
local ROOT = SRC:match("^(.*)/scripts/[^/]+$")
package.path = ROOT .. "/lua/?.lua;" .. package.path
local config = require("rex_develop.config")
config.set_root(ROOT)
local util = require("rex_develop.util")

local function fail(msg)
  io.stderr:write("Error: ", tostring(msg), "\n")
  os.exit(1)
end

local words = {}
for i = 1, select("#", ...) do
  words[i] = select(i, ...)
end
local name = table.remove(words, 1)
if not name or name == "-h" or name == "--help" then
  io.stderr:write("usage: cli.lua <action> [key=value ...] [--json] | --list\n")
  os.exit(name and 0 or 1)
end

local actions = require("rex_develop.actions")
if name == "--list" then
  for _, a in ipairs(actions.list) do
    print(a.name .. "\t" .. a.title)
  end
  return
end

local args = {}
for _, w in ipairs(words) do
  if w ~= "--json" then
    args[#args + 1] = w
  end
end
local a = actions.by_name[name]
if not a then
  fail(string.format("no action named %s; --list shows them", name))
end
local ok, res = pcall(function()
  return a.run(actions.parse(a.args, args))
end)
if not ok then
  fail(res)
end
print(util.json(res == nil and {} or res))
