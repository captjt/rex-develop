# rex-develop design

Draft, 2026-11-17. The decisions table marks what's settled.

rex-reviewer handles the PRs that request **you**: agents review them and
you post. rex-develop is the other half. It takes the issues assigned to
you in your tracker to an open PR, then answers the PR's reviews until it
merges.

The tracker is the source of truth for what to build. Development raises
questions the issue doesn't answer, and only a person can settle them.
Agents decide what they can. A decision only you can make, something for
you to look at, or a step that needs your approval reaches you as a
[rex-inbox](https://github.com/captjt/rex-inbox) message, on your Mac or
your phone, and your reply is the answer. Each PR carries its plan: what it
set out to do, and the decisions that shaped it. Reviewers, people and
agents alike, check the change against the plan.

```
Linear issue ─▶ plan ─▶ build ─▶ check ─▶ preview ─▶ open PR + plan ─▶ address reviews ─▶ merged
                 │        │         │         │           │                    │
                 └────────┴─ decisions and approvals: rex-inbox messages ──────┘
```

It runs like rex-reviewer: on your machine, in your Rex session, with your
own agents and skills. A watcher does the bookkeeping and spends no tokens.
The tools share no code. They work together through what each one
publishes: a ledger, program status records, rex-inbox messages, the plan
on the PR, and Rex actions.

rex-develop is a public project. Its docs, examples, fixtures, and
screenshots use a made-up workspace (team `ENG`, repo `acme/api`), and
nothing comes from a real company's tracker.

## Decisions

| Question | Decision | Status |
| --- | --- | --- |
| What starts work | An issue in a tracker. Every task is an issue. | decided |
| First tracker | Linear. GitHub Issues follows, behind the same adapter. | decided |
| Linear trigger | An issue assigned to you, in an unstarted state, that has the trigger label **or** is in its team's active cycle. | decided |
| Starting cycle issues | A labeled issue starts on its own, because the label is the opt-in. A cycle issue asks first: Start, Skip, or Not this cycle. | proposed |
| Decision channel | rex-inbox messages to you, with option buttons. Your reply is the answer. This needs rex-inbox's answer options on messages, and a tool's pane that messages you as itself (neither is in a rex-inbox release yet). | decided, for now |
| Decisions on the PR | Later. | decided |
| The plan | Evidence of the PR's intent, attached to the PR. The checker and rex-reviewer check the change against it. | decided |
| Writing to the tracker | Nothing in v1. Linear is read-only, and its own GitHub integration links the PR and moves the issue. | proposed |
| Public project | A made-up workspace in docs, examples, and tests. Nothing comes from a real tracker. | decided |
| Language | Lua, laid out like rex-reviewer. The watcher runs under LuaJIT in an ordinary Rex pane, with your shell's git and gh sign-ins. The agents never call actions (they write files), so nothing has to load into Rex; `init.lua` adds Rex actions for key bindings. | decided |
| Gates | `start` (cycle issues), `plan`, `preview`, `open`, `reply`: each `ask` or `auto`, defaulting to `ask`, except `start` for labeled issues. `rebase` always asks. | proposed |
| Merging | Never. A person merges. | decided |

## A task's life

### Intake

The watcher polls Linear every few minutes, with one GraphQL query that
uses your API key. It reads from Linear and never writes to it.
`decide(entry, observation, now)` is pure, so `rex-develop replay ENG-142`
can run the rules over an issue's history.

- **What it picks up:** an issue assigned to you whose state is `unstarted`
  (Todo), that either has the trigger label (`agent`) or is in its team's
  active cycle. Issues in progress are yours and are left alone, and so is
  the backlog.
  - Linear's filters cover this: `assignee.isMe`, the label `agent`, and
    the cycle's `isActive`. Check the exact filter names against the schema.
  - A `skip_label` (`no-agent`) leaves an issue out of the cycle trigger.
- **Starting:** a labeled issue queues at once. A cycle issue first sends
  you **Start**, **Skip**, or **Not this cycle**. The ledger remembers a
  Skip, so it doesn't ask again.
- **Order and limits:** by priority (Urgent first, no priority last), then
  the cycle's own order. `max_tasks` caps how many run at once.
- **Repo:** each Linear team maps to a repo in the config. A team with
  several repos picks one by label or project. If nothing picks one, the
  first message you get is a decision: which repo?
- **By hand:** `rex-develop start ENG-142` takes an issue that matches
  neither trigger.
- **Changes mid-task:**
  - The issue is unassigned, canceled, or moved to started by someone else.
    Before work starts, the task is dropped. After that, you get a message:
    **Stop** or **Keep going**.
  - New comments go into the task's context, and the builder gets them at
    its next stop.

### Round 1: build

1. **Prep.** The watcher makes a worktree from a fresh `origin/<base>`, on
   Linear's own `branchName` for the issue. That name is what lets Linear's
   GitHub integration link the PR and move the issue. The issue, its
   comments, its sub-issues and related issues, and the repo notes are
   fetched into `.tmp/context/`. Agents never call Linear or GitHub.
2. **Readiness.** The builder reads the issue first. If the issue can't be
   built as written, because it has no acceptance criteria or more open
   questions than `max_decisions`, you get **Not ready**:
   - **Proceed:** the builder goes ahead on its stated assumptions.
   - **Drop:** the task stops.
   - Your reply's text goes to the builder as more context.
3. **Plan** (gate `plan`). The builder writes `plan.md` in the plan format
   below, listing every decision it can foresee. You get the plan with
   **Approve**, **Revise**, or **Discard**, and each open decision as its
   own message. **Approve** accepts the recommendation for any decision
   you haven't answered, and the plan records that it stood unanswered.
4. **Build.** The same builder session implements, runs the repo's checks,
   and commits locally. New decisions can come up while it builds.
5. **Check.** A fresh checker, ideally a different agent from the builder,
   checks the diff against the plan:
   - every acceptance item has evidence, such as a test or a probe;
   - every decision was carried out as answered;
   - anything beyond the plan is called out or removed;
   - the repo's checks pass.

   Its findings go back to the builder, up to `fix_loops` times.
6. **Preview** (gate `preview`), when the plan says the change is
   something a person can see. The builder serves the app on its port, or
   leaves screenshots, a transcript, or a response. The watcher shares it
   with `rex-inbox share`, with **Looks right** and **Needs work**. Needs
   work takes text and starts a fix loop.
7. **Open** (gate `open`). The checker drafts the PR's title and body in
   the PR style guide, with `Closes ENG-142` and the plan attached (see
   below). You get **Open PR** or **Discard**, and the body and the plan
   are in the message. The action pushes and opens the PR from your
   account, with the footer.

### Round n: address reviews

- **What starts a round:** a submitted review with new threads or
  `CHANGES_REQUESTED`, after a settle time (reviewers add comments in
  bursts). A lone conversation comment is only noted.
- **The work:** the builder's session resumes, fixes, commits, and drafts
  one reply per thread. The checker confirms each "Fixed in <sha>". The
  plan gets a new entry under **Changes since the plan** whenever review
  changes what the PR does.
- **Gate `reply`:** you get **Push & reply** or **Discard**. Then the
  action pushes, posts the replies, updates the plan on the PR, and
  re-requests the reviewers.
- **Other rounds:** a `ci` round fixes failing checks when `fix_ci` is on.
  A `rebase` round resolves conflicts with the base, and always asks,
  because it force-pushes.
- **What it never does:** resolve threads.
- **The end:** when the PR merges or closes, the worktree, branch and panes
  are cleaned up, and the history and tokens are recorded.

## The plan: evidence of intent

The plan is the contract between the issue and the PR. The builder writes
it before writing code, you approve it, the checker holds the diff to it,
and it goes out with the PR so reviewers can do the same. It says what the
PR set out to do, which is what a reviewer needs to judge whether the
change did it.

```markdown
<!-- rex-develop:plan v1 ENG-142 -->
<details open><summary><b>Plan</b> · ENG-142 · approved by @you</summary>

**Intent.** Webhook deliveries that fail now retry with backoff, so a
receiver's brief outage no longer drops events. From ENG-142.

**Acceptance**
- A delivery that gets a 5xx or times out retries up to 5 times, with
  backoff: `webhooks::retry::backs_off` and `gives_up_after_five`.
- Each attempt is logged with its status: `webhooks::retry::logs_attempts`.

**Decisions**
- **D1 · Retries cover 5xx and timeouts, not 4xx.** A 4xx means the
  receiver rejected the payload. Chosen by @you.
- **D2 · Up to 5 attempts.** The recommendation stood; nobody answered.

**Out of scope**
- A dead-letter queue (ENG-150).

**Changes since the plan**
- Round 2: retries also cover `429`, with `Retry-After` honored, per review.

</details>
<!-- /rex-develop:plan -->
```

- **Where it goes:** at the end of the PR body, between markers. The
  actions rewrite only what lies between the markers, every round, and
  leave the rest of the body alone. On GitHub it's the first thing a
  reviewer sees. The full `plan.md`, with the builder's notes, stays in the
  ledger.
- **Acceptance items** come from the issue, each with the test or probe
  that shows it. If the issue has no criteria, the builder writes them and
  the plan says so. Approving the plan approves them.
- **Decisions** say who made each one, or that the recommendation stood.
  Each one can link to the message thread where you answered it.
- **Validation:**
  - **The checker,** before the PR opens: the diff against the plan, item
    by item.
  - **rex-reviewer,** on the PR: its ground rules already count "a change
    that contradicts the PR's own description" as blocking. A small
    rex-reviewer change makes its reviewers read the plan block and check
    every acceptance item and decision against the code. A teammate's
    rex-reviewer then checks your agent's PR against its plan.
  - **People:** the intent and the decisions sit where they review.
- **Public repo, private tracker:** if a public repo's issues live in a
  private Linear workspace, the plan would publish their content. A repo's
  `plan` setting is `full`, `summary` (intent and acceptance in the
  builder's words, no quotes, no comment text), or `false`. A repo that
  `gh` reports as public defaults to `summary`.

## Decisions and approvals: rex-inbox messages

### What counts as a decision

A decision is a question that the issue, its comments, the code, and the
repo's conventions don't settle, where a wrong guess costs real rework or
changes what users, other teams, or data see:
- product behavior;
- an API or schema shape;
- a migration;
- a scope cut or addition;
- a new dependency or service;
- a security or privacy stance.

Names, structure, and test layout have conventional defaults. The agent
picks one and notes it in the plan. The ground rules say this, because an
agent that asks about everything is worse than one that asks about
nothing.

### How one travels

1. **The agent writes a file.** It never calls rex-inbox itself. The
   watcher is outside the sandbox, works on either host, and owns the
   record that the plan needs.

   ```json
   // .tmp/decisions/D1.json
   {
     "id": "D1",
     "question": "Should retries cover 4xx responses?",
     "why": "The issue says \"retry failed webhooks\". A 4xx usually means the receiver rejected the payload, so retrying it may flood them.",
     "options": [
       { "label": "5xx and timeouts only", "detail": "Rejected payloads fail at once and show in the log." },
       { "label": "Every non-2xx", "detail": "Simpler, but a bad payload is sent 5 times." }
     ],
     "recommend": 0,
     "mode": "provisional",
     "meanwhile": "Building with 5xx and timeouts only. Switching later is a one-line change."
   }
   ```

2. **The watcher sends you a message** with option buttons:

   ```
   ENG-142 · D1 · Should retries cover 4xx responses?

   The issue says "retry failed webhooks". A 4xx usually means the receiver
   rejected the payload, so retrying it may flood them.

   1. 5xx and timeouts only (recommended): rejected payloads fail at once…
   2. Every non-2xx: simpler, but a bad payload is sent 5 times.

   Meanwhile: building with 5xx and timeouts only.

   [5xx and timeouts only]  [Every non-2xx]  Reply…
   ```

3. **Your reply is the answer.** It can be a button, text, or both, such
   as "2, but cap it at 3". The watcher finds the decision from the
   message's thread and writes `D1.answer.json` (`choice`, `text`, `by`,
   `at`, `thread`). Then:
   - A parked builder is prompted to continue.
   - A working builder reads the answer at its next stop.
   - An answer that goes against a provisional choice becomes rework, and
     the checker confirms the rework was done.
4. **A late reply** to a decision, gate, or round that has moved on gets a
   reply saying so, and changes nothing.

More rules:
- **`provisional` or `blocking`.** A provisional decision means the agent
  keeps building on its recommendation. Use it when the choice is cheap to
  reverse. A blocking decision means the agent writes `DECISION D1` to its
  status and stops. Use it only when building either way would waste the
  work.
- **Batch.** Decisions the agent can foresee come with the plan, all at
  once. Ones that come up mid-build go out as they happen.
- **A cap.** More than `max_decisions` open at once sends the task back to
  readiness.
- **Without rex-inbox,** `rex-develop ls` lists what waits on you, and
  `rex-develop answer ENG-142 D1 1 "…"` answers it. Rex shows the status
  records either way.

### What you get

| Message | Subject | Buttons (a reply can add text) |
| --- | --- | --- |
| Cycle issue | `ENG-142 · in your cycle · Retry failed webhooks` | Start, Skip, Not this cycle |
| Not ready | `ENG-142 · not ready: no acceptance criteria` | Proceed, Drop |
| Decision | `ENG-142 · D1 · Should retries cover 4xx?` | each option, recommended first |
| Plan | `ENG-142 · plan · 2 acceptance items, 2 decisions` | Approve, Revise, Discard |
| Preview | `ENG-142 · the new retry settings` (shared app) | Looks right, Needs work |
| Ready to open | `ENG-142 · 4 commits, checks pass, 1 recommendation stood` | Open PR, Discard |
| Fixes ready | `api#341 · round 2 · 3 fixed, 1 kept` | Push & reply, Discard |
| Issue changed | `ENG-142 · canceled in Linear` | Stop, Keep going |
| Blocked, failed | `ENG-142 · builder: <why>` | (open the pane) |

### What rex-inbox needs

- **Option buttons on plain messages:** `rex-inbox send --to me --option
  A --option B`. Previews already ride on a message with options, so this
  extends what exists. The phone and notifications show the buttons, and a
  button with text sends both.
- **Replies the watcher can read:** messages to a pane that isn't an agent
  queue, and the watcher reads its replies each tick with `rex-inbox inbox
  --json`. Check this: the watcher's identity as a caller (its pane's block
  id) when it runs under `rex do`.
- **Later:**
  - "app items": a tool's own cards in the inbox, built from its status
    records and an `inbox.json`.
  - rex-develop's panes folded under their issue, as rex-reviewer's are,
    which ends their Finished items and gives them labels like `ENG-142 ·
    builder`. Until then, builder and checker panes can raise Finished
    items like any agent.
  - rex-reviewer moved onto the same mechanism.

## Trackers

Each tracker is an adapter in `lua/rex_develop/trackers/`. v1 only reads.

| Call | Does |
| --- | --- |
| `query(tracked)` | one observation per issue: key, title, url, state type, assignee, labels, cycle and whether it's active, priority, branch name, team, project, `updated_at`, new comments |
| `context(issue, dir)` | write `issue.json`, `comments.json`, and sub-issues and related issues into `.tmp/context/` |
| `branch(issue)` | the branch name: Linear's `branchName`, or `<prefix><n>-<slug>` |
| `closes(issue)` | the PR body's link: `Closes ENG-142` or `Closes #45` |

- **Linear** goes through its GraphQL API with a personal API key, from the
  Keychain or `LINEAR_API_KEY`. The key only needs read access.
- **GitHub Issues** goes through `gh`, signed in as you.
- **Later, opt-in:**
  - `comment` and `set_state`, so decisions are recorded on the issue too;
  - answers taken from the PR, then the issue;
  - Linear as an agent app: you delegate an issue to "Rex", and decisions
    become `elicitation` activities in its agent session. That needs an
    OAuth app installed in the workspace and a public webhook endpoint.
- **Issue text is data, not instructions.** Anyone with access can write an
  issue or a comment. The agents can't push or reach credentials, and
  every outward step goes through your approval.

## With rex-reviewer

- **One model.** Both tools have the same pieces: the ledger layout,
  `events.jsonl`, status records, actions that take `item=`, hosts (Rex or
  Herdr), guide slots, effort functions, and brief overrides.
- **No overlap.** rex-reviewer only picks up PRs that request you by name,
  and rex-develop only handles PRs it opened or adopted.
- **The plan.** rex-reviewer checks a PR against its plan block, as
  described above.
- **The loop across people.** rex-develop requests reviewers. A teammate's
  rex-reviewer reviews the PR against its plan, rex-develop addresses the
  review and re-requests, and that starts their round 2.
- **Pre-review (later).** The check stage hands the branch to rex-reviewer
  as a local round that never posts.

## Safety

The develop side writes code and pushes, so it needs a harder wall than
rex-reviewer. There, `gh` is signed out, and the agents never push because
their worktrees are detached. Here, the agents commit on a real branch.

- **Agents commit and never push.** Several layers block a push:
  - `gh` is signed out.
  - No Linear key is in the agents' environment.
  - Environment-level git config (`GIT_CONFIG_COUNT`) points `pushurl` at
    a URL that can't work and clears the credential helper.
  - `GIT_SSH_COMMAND=false` and no `SSH_AUTH_SOCK` close the SSH route.
  - Claude Code deny rules block `git push` and `gh`.
- **Only actions push or open PRs.** They run outside the sandbox. They
  refuse in these cases:
  - a branch that isn't the task's own;
  - the base or default branch;
  - a force-push outside an approved `rebase` round;
  - a remote branch that moved since the round started;
  - a body without the footer or the plan block.
- **Never:** merge, resolve threads, close PRs, write to the tracker (in
  v1), push to someone else's branch, or touch an issue or PR it didn't
  take on.

## Config sketch

```lua
return {
  trackers = {
    linear = {
      label = "agent",            -- labeled issues start on their own
      cycle = true,               -- active-cycle issues ask first
      skip_label = "no-agent",
      teams = { ENG = "acme/api" },  -- or a function(issue) returning a repo
    },
  },
  repos = {
    ["acme/api"] = { checkout = "~/src/api", base = "main", notes = "Run `make test`." },
  },
  builder = "claude",
  checker = "codex",
  gates = { start = { label = "auto", cycle = "ask" }, plan = "ask", preview = "ask", open = "ask", reply = "ask" },
  max_decisions = 3,
  pr = { draft = true, reviewers = {} },
  -- plan = "full",               -- per repo: "full", "summary", or false
  fix_loops = 2,
  fix_ci = true,
  max_tasks = 2,
  guides = {
    plan = false, build = false, check = false,
    pr_style = "bundled",         -- or a path to your own PR skill
    reply_style = "bundled",      -- or a path to your own reply skill
  },
  effort = { build = "high", check = "high" },
}
```

## Pieces

```
init.lua                 Rex actions: develop_start, _answer, _focus, _pause, _resume, _up, _down
scripts/                 watcher, CLI under LuaJIT, start, replay
lua/rex_develop/         config, ledger, rules, decisions, messages, plan, agents, rounds,
                         watcher, status, actions
lua/rex_develop/trackers linear, github
lua/rex_develop/hosts/   rex, herdr
briefs/                  ground rules, readiness, plan, build, check, preview, address, ci, rebase
guides/                  plan format, default PR and reply style
bin/                     rex-develop, open-pr, post-replies, rex-agent, token-usage
tests/fixtures/          made-up Linear and GitHub responses, and issue histories for replay
docs/                    ledger, decisions, the plan block, trackers, hosts
```

State lives in `~/.local/state/rex-develop/`:
- `state.json`
- `watcher.json`
- `events.jsonl`
- `tasks/<tracker>/<key>.json`

The ledger keeps each task's plan, its decisions and their answers, and
the message threads, so the history outlives the worktree.

## Build steps

Each step is usable on its own. Status as of 2026-11-17:
- **Steps 1 and 2:** built, with the Linear adapter tested against a made-up
  workspace.
- **Step 3:** half built. The preview gate works with a file; a served app
  is shared through `rex-inbox share`, but hasn't been tried on a real
  tailnet.
- **Step 5:** built early, so rex-develop can run on GitHub alone. Its
  mapping is tested, and it hasn't run against GitHub yet.
- **Tests:** `tests/e2e.sh` runs the whole of round 1 in Rex with stand-in
  agents, through the CLI and through a rex-inbox hub of its own.

1. **rex-inbox: option buttons on plain messages.** Small, and every
   message later needs it.
2. **rex-develop core on Linear.**
   - Intake by label and active cycle, with the start gate.
   - Prep, readiness, and the plan with decisions, all over messages.
   - Build, and check against the plan.
   - Open the PR with the plan block.
   - Tests on made-up fixtures.
3. **Previews** through `rex-inbox share`.
4. **rex-reviewer checks the plan block.**
5. **The GitHub Issues adapter.**
6. **The address loop,** with the plan's "Changes since the plan."
7. **CI and rebase rounds.**
8. **Later:**
   - rex-inbox app items and folded panes;
   - decisions on the PR;
   - Linear write-back, and Linear as an agent app;
   - Herdr as a host, pre-review, and a Develop recap.

## Open questions

- Is "label starts on its own, cycle asks first" the right default?
- One agent budget across rex-reviewer and rex-develop, or separate
  `max_rounds` and `max_tasks`?
- Dogfooding: GitHub Issues on `captjt/rex-develop` itself, labeled `agent`.
- rex-develop's builder and checker panes still raise Finished items in
  rex-inbox like any agent, until rex-inbox folds a tool's panes the way it
  does rex-reviewer's.
