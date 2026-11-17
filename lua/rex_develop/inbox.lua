-- rex-inbox, when it runs: how rex-develop reaches you. Every gate and
-- decision is a message to you from the watcher's pane, with its answers as
-- buttons, and your reply is the answer. Previews ride on rex-inbox's
-- sharing. Replies queue for the watcher's pane (it isn't an agent, so the
-- hub never types into it), and each step reads the new ones.
--
-- It talks to rex-inbox only through its CLI, as the watcher's pane: the
-- pane's REX_SESSION and REX_BLOCK say who's asking. config.inbox = false
-- turns it off; "auto" uses it while its hub answers.

local util = require("rex_develop.util")
local config = require("rex_develop.config")
local ledger = require("rex_develop.ledger")

local M = {}

local state = { checked_at = 0, up = false, no_options = false }

local function cli(args, opts)
  return util.run(util.append({ "rex-inbox" }, args), opts or { check = false })
end

-- Whether to send through rex-inbox now.
function M.available()
  local mode = config.load().inbox
  if mode == false then
    return false
  end
  if os.getenv("REX_BLOCK") == nil or os.getenv("REX_BLOCK") == "" then
    return false
  end
  if os.time() - state.checked_at < 30 then
    return state.up
  end
  state.checked_at = os.time()
  local res = cli({ "status" })
  state.up = res.ok
  return state.up
end

-- Send a message to you. Returns its id. options are button labels.
function M.send(subject, body, options)
  local args = { "send", "--to", "me", "--subject", subject }
  local text = body
  if options and #options > 0 and not state.no_options then
    for _, o in ipairs(options) do
      util.append(args, { "--option", o })
    end
  elseif options and #options > 0 then
    text = body .. "\n\nAnswer with " .. table.concat(options, ", ") .. "."
  end
  args[#args + 1] = "-"
  local res = cli(args, { check = false, input = text })
  if not res.ok and not state.no_options and (res.stderr or ""):find("--option", 1, true) then
    -- An older rex-inbox without answer buttons: say the answers instead.
    state.no_options = true
    return M.send(subject, body, options)
  end
  if not res.ok then
    error("rex-inbox send: " .. util.trim(res.stderr ~= "" and res.stderr or res.stdout):sub(1, 300), 0)
  end
  local id = tonumber((res.stdout or ""):match("#(%d+)"))
  if not id then
    error("rex-inbox send gave no message id: " .. util.trim(res.stdout):sub(1, 200), 0)
  end
  return id
end

-- Share an app served on port, as a preview with answers. Returns the
-- message id it rides on.
function M.share(port, title, ask, options)
  local args = { "share", tostring(port), "--title", title, "--ask", ask, "--json" }
  for _, o in ipairs(options or {}) do
    util.append(args, { "--option", o })
  end
  local res = cli(args)
  if not res.ok then
    error("rex-inbox share: " .. util.trim(res.stderr ~= "" and res.stderr or res.stdout):sub(1, 300), 0)
  end
  local j = util.decode(res.stdout) or {}
  local id = j.id or (j.message and j.message.id)
  if not id then
    error("rex-inbox share gave no message id", 0)
  end
  return id, j.url
end

function M.stop_share(port)
  cli({ "share", "--stop", tostring(port) })
end

-- Reply in a thread, such as to say an answer came too late.
function M.reply(id, text)
  cli({ "reply", tostring(id), "-" }, { check = false, input = text })
end

-- The replies to rex-develop's messages that haven't been taken yet:
-- { id, ref (what the message stood for), choice, body }. Each is taken
-- once: the ledger remembers the newest reply id it read.
function M.replies()
  local res = cli({ "inbox", "--json" })
  if not res.ok then
    return {}
  end
  local j = util.decode(res.stdout)
  local list = type(j) == "table" and (j.messages or j) or {}
  local last = tonumber(ledger.load_state().inbox_last) or 0
  local out, newest = {}, last
  for _, m in ipairs(util.list(list)) do
    local id = tonumber(m.id)
    if id and id > last then
      newest = math.max(newest, id)
      local ref = (m.reply_to and ledger.thread(m.reply_to)) or (m.thread_id and ledger.thread(m.thread_id))
      if ref then
        out[#out + 1] = { id = id, ref = ref, choice = m.choice, body = m.body, to = m.reply_to or m.thread_id }
      end
      cli({ "read", tostring(id), "--json" })
    end
  end
  if newest > last then
    ledger.update_state(function(st)
      st.inbox_last = newest
    end)
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

return M
