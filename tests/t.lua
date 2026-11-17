-- A small test harness. Each test file does
--
--   local t = dofile(ROOT .. "/tests/t.lua")
--   t.eq("name", got, want)
--   t.done()
--
-- and needs nothing but LuaJIT.

local M = { pass = 0, fail = 0 }

local function show(v)
  if type(v) == "table" then
    local ok, util = pcall(require, "rex_develop.util")
    if ok then
      return util.json(v)
    end
  end
  return tostring(v)
end

function M.eq(name, got, want)
  local a, b = show(got), show(want)
  if a == b then
    M.pass = M.pass + 1
  else
    M.fail = M.fail + 1
    print(string.format("FAIL %s\n  got:  %s\n  want: %s", name, a, b))
  end
end

function M.ok(name, v)
  M.eq(name, v and true or false, true)
end

function M.has(name, s, sub)
  if type(s) == "string" and s:find(sub, 1, true) then
    M.pass = M.pass + 1
  else
    M.fail = M.fail + 1
    print(string.format("FAIL %s\n  %q\n  doesn't contain %q", name, tostring(s), sub))
  end
end

function M.done(file)
  print(string.format("%s: %d passed, %d failed", file or "tests", M.pass, M.fail))
  os.exit(M.fail == 0 and 0 or 1)
end

return M
