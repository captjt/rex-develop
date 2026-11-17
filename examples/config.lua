-- ~/.config/rex-develop/config.lua
--
-- rex-develop takes the issues assigned to you in your tracker to PRs. A
-- builder agent plans and builds each one, a checker agent checks it
-- against the plan, and you approve the plan and the PR, and answer the
-- decisions only you can make, through rex-inbox when it runs.

return {
  -- The Rex session the watcher and the task tabs open in.
  -- session = "rex-develop",

  trackers = {
    -- Linear: an issue assigned to you, in an unstarted state (Todo), that
    -- has the label or is in its team's active cycle. Run
    -- `rex-develop setup-linear` to store your API key in the Keychain.
    linear = {
      label = "agent",          -- labeled issues start on their own; false for none
      cycle = true,             -- active-cycle issues are offered first; false for none
      skip_label = "no-agent",  -- leaves an issue out of the cycle
      -- Each team's repo. A list lets the issue pick by a label that
      -- names the repo; otherwise you're asked which.
      teams = { ENG = "acme/api" },
      -- projects = { ["Webhooks v2"] = "acme/webhooks" },  -- over the team's
      -- Or a function(issue) that returns a repo, or a list to ask from:
      -- teams = function(issue) return issue.project == "Web" and "acme/web" or "acme/api" end,
      -- Where the key comes from, first that has one:
      -- key = { keychain = "rex-develop-linear", env = "LINEAR_API_KEY" },
    },

    -- GitHub Issues: an open issue in one of your repos, assigned to you,
    -- with the label.
    -- github = { label = "agent" },
  },

  repos = {
    ["acme/api"] = {
      -- A clone whose origin is the repo. Each task's worktree hangs off it.
      checkout = "~/src/api",
      -- base = "main",          -- the branch tasks start from; origin's default if unset
      -- Anything the agents should know that the repo's own docs don't say.
      notes = [[
- Run `make test`; the e2e suite needs Docker, so skip it.
]],
      -- plan = "full",          -- the plan on the PR: "full", "summary", or false.
      --                         -- Unset: "summary" for a public repo, "full" otherwise.
      -- builder = "codex",      -- this repo's own builder or checker
    },
  },

  -- Who builds and who checks: "claude" or "codex", or a table with
  -- extra_args and effort (low, medium, high, xhigh, max).
  builder = "claude",
  checker = "codex",
  -- builder = { agent = "claude", extra_args = { "--model", "claude-opus-5-5" }, effort = "high" },

  -- How each approval goes: "ask" waits for you, "auto" goes on its own.
  -- start: labeled issues ("label") and cycle issues ("cycle").
  gates = {
    start = { label = "auto", cycle = "ask" },
    plan = "ask",
    preview = "ask",
    open = "ask",
  },

  -- "auto" sends what waits on you through rex-inbox while its hub runs;
  -- true insists on it; false never uses it (rex-develop ls and answer).
  inbox = "auto",

  -- More decisions than this, open at once, means an issue isn't ready.
  max_decisions = 3,
  -- Tasks with an agent working at once. One waiting on you doesn't count.
  max_tasks = 2,
  -- Rounds of the checker's findings the builder fixes before you decide.
  fix_loops = 2,
  -- How often to check the trackers.
  poll_seconds = 180,

  pr = {
    draft = true,
    reviewers = {},           -- GitHub logins to request
  },

  -- GitHub issues' branches: <prefix><number>-<title words>. Linear names its own.
  branch_prefix = "agent/",

  -- Guides point the agents at your own skills or instructions. Each is a
  -- path to a file, a string, "bundled" for the one in guides/, or false.
  guides = {
    plan = false,             -- more on how to plan
    build = false,            -- more on how to build
    check = false,            -- more for the checker
    pr_style = "bundled",     -- how the PR's title and body read
    plan_format = "bundled",  -- the plan's sections
  },

  -- Agent programs and arguments. args replaces an agent's defaults;
  -- extra_args adds to them.
  agents = {
    claude = {
      -- program = "/opt/homebrew/bin/claude",
    },
    codex = {
      -- extra_args = { "-c", "mcp_servers.linear.enabled=false" },
    },
  },

  -- Extra folders for PATH, and caches the agents may write to.
  path = {},
  extra_caches = {},

  hooks = {
    -- Return false to leave an issue alone. It gets the observation:
    -- key, title, labels, team, project, priority, repo.
    -- should_take = function(issue) return issue.priority ~= 4 end,
  },
}
