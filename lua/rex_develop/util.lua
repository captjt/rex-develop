-- Commands, files, and time: the small helpers the other modules share.

local runtime = require("rex_develop.runtime")

local M = {}

local HOME = os.getenv("HOME")
local USER = os.getenv("USER") or ""
M.HOME = HOME

-- Rex runs actions with only the system directories on PATH, and a
-- LaunchAgent starts with little more, so every command gets this PATH.
-- The config's `path` list goes in front.
local base_path = {
  HOME .. "/.local/bin",
  HOME .. "/.bin",
  HOME .. "/bin",
  HOME .. "/.cargo/bin",
  "/opt/homebrew/bin",
  "/opt/homebrew/sbin",
  HOME .. "/.nix-profile/bin",
  "/etc/profiles/per-user/" .. USER .. "/bin",
  "/run/current-system/sw/bin",
  HOME .. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS",
  "/usr/local/bin",
  "/usr/bin",
  "/bin",
  "/usr/sbin",
  "/sbin",
}
M.PATH = table.concat(base_path, ":")

function M.set_extra_path(dirs)
  local all = {}
  for _, d in ipairs(dirs or {}) do
    all[#all + 1] = M.expand(d)
  end
  for _, d in ipairs(base_path) do
    all[#all + 1] = d
  end
  M.PATH = table.concat(all, ":")
end

-- Run argv to the end. Errors unless opts.check is false. opts.input is
-- text for the command's stdin; opts.env adds to the environment.
function M.run(argv, opts)
  opts = opts or {}
  local env = { PATH = M.PATH }
  for k, v in pairs(opts.env or {}) do
    env[k] = v
  end
  local input_file
  if opts.input then
    input_file = os.tmpname()
    local f = assert(io.open(input_file, "w"))
    f:write(opts.input)
    f:close()
    local wrapped = { "/bin/sh", "-c", 'f=$1; shift; exec "$@" < "$f"', "sh", input_file }
    argv = M.append(wrapped, argv)
  end
  local res = runtime.exec(argv, { cwd = opts.cwd or HOME, env = env })
  if input_file then
    os.remove(input_file)
  end
  if opts.check ~= false and not res.ok then
    local shown = {}
    for i = (input_file and 6 or 1), #argv do
      shown[#shown + 1] = argv[i]
    end
    local err = (res.stderr ~= "" and res.stderr) or res.stdout or ""
    error(string.format("%s exited %s: %s", table.concat(shown, " "):sub(1, 120), tostring(res.code), err:sub(1, 600)), 0)
  end
  return res
end

function M.trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.expand(path)
  if type(path) ~= "string" then
    return path
  end
  return (path:gsub("^~/", HOME .. "/"):gsub("^~$", HOME))
end

function M.exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

function M.mkdirp(path)
  M.run({ "mkdir", "-p", path })
end

function M.read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

-- Written whole, then renamed, so a reader never sees half a file.
function M.write_file(path, s)
  local tmp = path .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(s)
  f:close()
  assert(os.rename(tmp, path))
end

function M.append_file(path, s)
  local f = assert(io.open(path, "a"))
  f:write(s)
  f:close()
end

-- The files in dir whose names match a Lua pattern, sorted.
function M.list_dir(dir, pattern)
  local res = M.run({ "/bin/ls", "-1", dir }, { check = false })
  local out = {}
  if not res.ok then
    return out
  end
  for name in (res.stdout or ""):gmatch("[^\n]+") do
    if not pattern or name:match(pattern) then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

function M.now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- Epoch seconds from a UTC time as M.now() writes it.
function M.epoch(iso)
  local y, mo, d, h, mi, s = (iso or ""):match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s), isdst = false })
  -- os.time reads the table as local time; move it back to UTC.
  local utc = os.time(os.date("!*t", t))
  return t + (t - utc)
end

function M.short(sha)
  return sha and sha:sub(1, 7) or "?"
end

function M.split_slug(slug)
  return (slug or ""):match("^([^/]+)/([^/]+)$")
end

-- Fill {{NAME}} placeholders. Unknown names stay as they are.
function M.render(template, vars)
  return (template:gsub("{{([%w_]+)}}", function(k)
    local v = vars[k]
    return v ~= nil and tostring(v) or "{{" .. k .. "}}"
  end))
end

function M.append(list, items)
  for _, v in ipairs(items or {}) do
    list[#list + 1] = v
  end
  return list
end

function M.contains(list, x)
  for _, v in ipairs(list or {}) do
    if v == x then
      return true
    end
  end
  return false
end

-- Lua writes an empty table as {}. Readers of the ledger accept both.
function M.json(v)
  return runtime.encode(v)
end

function M.decode(s)
  local ok, v = pcall(runtime.decode, s or "")
  return ok and v or nil
end

-- A list read from JSON: an empty one may come back as {} or nil.
function M.list(v)
  return type(v) == "table" and v or {}
end

function M.sleep(seconds)
  M.run({ "sleep", tostring(seconds) }, { check = false })
end

return M
