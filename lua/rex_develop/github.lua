-- GitHub, through gh, for the PR side: who you are, whether a repo is
-- public, opening a PR, and what became of it.

local util = require("rex_develop.util")

local M = {}

local login_cache

function M.login()
  if login_cache then
    return login_cache
  end
  local res = util.run({ "gh", "api", "user", "--jq", ".login" }, { check = false })
  local login = util.trim(res.stdout)
  if not res.ok or login == "" then
    error("gh isn't signed in; run gh auth login", 0)
  end
  login_cache = login
  return login
end

-- true when the repo is public, so the plan on its PR mustn't quote a
-- private tracker.
function M.is_public(slug)
  local res = util.run({ "gh", "repo", "view", slug, "--json", "visibility", "--jq", ".visibility" }, { check = false })
  return util.trim(res.stdout):upper() == "PUBLIC"
end

-- Open a PR. Returns { number, url }.
function M.create_pr(o)
  local argv = { "gh", "pr", "create", "--repo", o.repo, "--base", o.base, "--head", o.head,
    "--title", o.title, "--body-file", "-" }
  if o.draft then
    argv[#argv + 1] = "--draft"
  end
  for _, r in ipairs(o.reviewers or {}) do
    argv[#argv + 1] = "--reviewer"
    argv[#argv + 1] = r
  end
  local res = util.run(argv, { input = o.body, cwd = o.cwd })
  local url = util.trim(res.stdout):match("(https://%S+/pull/%d+)")
  if not url then
    error("gh pr create said: " .. util.trim(res.stdout .. " " .. res.stderr):sub(1, 300), 0)
  end
  return { url = url, number = tonumber(url:match("/pull/(%d+)$")) }
end

-- An open PR for the branch, if there is one: a retry after a failure
-- partway shouldn't open a second.
function M.pr_for_branch(repo, branch)
  local res = util.run({ "gh", "pr", "list", "--repo", repo, "--head", branch, "--state", "open",
    "--json", "number,url", "--jq", ".[0] // empty" }, { check = false })
  local j = util.decode(util.trim(res.stdout))
  return j and j.number and j or nil
end

-- The PR's state: OPEN, MERGED, or CLOSED.
function M.pr_state(repo, number)
  local res = util.run({ "gh", "pr", "view", tostring(number), "--repo", repo, "--json", "state", "--jq", ".state" }, { check = false })
  local s = util.trim(res.stdout)
  return res.ok and s ~= "" and s or nil
end

return M
