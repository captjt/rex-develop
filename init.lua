-- rex-develop: Rex actions, optional. The watcher doesn't need them; they're
-- for key bindings and for tools that act on the watcher's status records.
-- Load it from ~/.config/rex/init.lua:
--
--   dofile(os.getenv("HOME") .. "/path/to/rex-develop/init.lua")
--
-- Then `rex do develop_answer task=ENG-142 what=plan choice=Approve`.
-- Actions that take longer than Rex allows (30 s), or need your shell's
-- sign-ins, stay in bin/rex-develop.

local ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/[^/]+$")
package.path = ROOT .. "/lua/?.lua;" .. package.path

local config = require("rex_develop.config")
config.set_root(ROOT)
local actions = require("rex_develop.actions")

for _, a in ipairs(actions.list) do
  if a.rex then
    rex.action({
      name = a.name,
      title = "Rex Develop: " .. a.title,
      args = a.args,
      run = function(_, args)
        return a.run(args or {})
      end,
    })
  end
end
