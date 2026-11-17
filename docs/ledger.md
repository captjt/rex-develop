# The ledger

Everything rex-develop knows lives in plain files under
`~/.local/state/rex-develop/`. The watcher writes them; the CLI, and
anything you build, read them. This page is the contract. `schema` is 1; a
change that breaks readers bumps it.

```
~/.local/state/rex-develop/
  state.json
  watcher.json
  events.jsonl
  check-now
  answers/*.json
  tasks/<id>.json
```

Files are written whole and renamed into place. Times are UTC, as
`2026-11-17T19:42:05Z`. Lua writes an empty list as `{}`, so accept `{}`
where a list is expected.

## state.json

| Field | Meaning |
| --- | --- |
| `schema` | 1 |
| `paused` | `true` while new tasks don't start |
| `stopped` | `true` after `rex-develop down` |
| `session_id` | the Rex session the watcher and task tabs run in |
| `last_scan_at` | the last tracker check |
| `seq` | the last event's number |
| `threads` | rex-inbox message id → `{ task, what, version }`: the ask a message stands for |
| `inbox_last` | the newest rex-inbox reply the watcher has taken |

## watcher.json

Written at every step (every 5 seconds).

| Field | Meaning |
| --- | --- |
| `at` | when |
| `attention` | problems: `{ task, label, title, kind, what, text }`, kind `blocked` or `error` |
| `waiting` | asks: `{ task, label, title, what, kind, subject, options, version, message_id, asked_at, error }` |
| `inbox` | whether rex-inbox carried the asks |
| `scan_error`, `error` | what failed |

## check-now and answers/

Any client may create `check-now`; the watcher checks the trackers within
5 seconds. An action that answers an ask leaves `answers/<time>.json`
(`{ task, what, version, choice, text, via }`) and the watcher applies it
on its next step. Clients never write tasks.

## events.jsonl

One object a line: `{ seq, at, kind, task, note }`. Kinds include `queued`,
`offered`, `dropped`, `started`, `asked`, `answered`, `decision`, `decided`,
`planned`, `plan-approved`, `checking`, `checked`, `fixing`, `opened`,
`merged`, `closed`, `discarded`, `issue-changed`, `paused`, and `resumed`.

## tasks/&lt;id&gt;.json

One per issue rex-develop has taken on. The id is the tracker and the key:
`linear-ENG-142`, or `github-acme-api-45` for acme/api#45.

| Field | Meaning |
| --- | --- |
| `id`, `tracker`, `key` | the task, its tracker (`linear` or `github`), and the issue's key |
| `issue_id`, `number` | Linear's id for the issue; GitHub's number |
| `title`, `url`, `priority`, `labels`, `issue_state` | from the tracker |
| `trigger` | what started it: `label`, `cycle`, or `manual` |
| `state` | `offered`, `queued`, `skipped`, `deferred`, `active`, `open`, `dropped`, `discarded`, `merged`, or `closed` |
| `phase` | while `active`: `planning`, `not_ready`, `plan_gate`, `building`, `checking`, `preview_gate`, `open_gate`, or `opening` |
| `repo`, `repo_choices` | the repo it builds in, or the ones you're asked to pick from |
| `branch`, `base`, `base_head` | the task's branch, the branch it started from, and that branch's head then |
| `worktree`, `port` | where it builds, and the port for its servers |
| `session_id`, `pane`, `checker_pane` | the Rex session and the agents' pane names |
| `builder_agent`, `builder_session`, `checker_agent`, `checker_session` | which agent each is, and its session |
| `asks` | what waits on you, by what: `{ what, kind, subject, body, options, version, message_id, asked_at }`. `kind` is `gate` or `decision` |
| `decisions` | by id: `{ question, options, recommend, mode, why, meanwhile, raised_at, answer }`; `answer` is `{ choice, label, text, by, via, at, stood }` |
| `plan_text`, `plan_version`, `plan_approved_by` | the plan as approved, how many versions it took, and who approved it (absent when automatic) |
| `check_n`, `fix_loops_used`, `last_check` | the checks so far, the fix rounds, and the last check's `{ n, verdict, findings, summary }`, with its findings as the checker wrote them |
| `built_head`, `checked_head`, `pushed_head` | heads along the way; only `checked_head` is pushed |
| `pr` | `{ number, url, opened_at }` once it's open |
| `issue_changed`, `issue_changed_kept` | a change to the issue under a working task, and one you said to keep going through |
| `start_error`, `open_error`, `dropped_reason`, `discarded_reason` | why something didn't happen |
| `created_at`, `queued_at`, `started_at`, `ended_at`, `updated_at` | times |

## Acting on it

Through the actions, never by writing a task:

```sh
rex-develop answer ENG-142 plan Approve
rex-develop do develop_answer task=ENG-142 what=D1 choice=2 text="but cap it at 3"
rex-develop do develop_answer item=task/linear-ENG-142/plan choice=Approve
```

An answer names the ask's version (rex-inbox replies carry it through
`threads`; the CLI uses the current one). One that comes after the ask moved
on changes nothing.

## The watcher's status records

The watcher reports program status (OSC 7501) on its pane: a root record
(`app=rex-develop`, `idle`, or `error` when a step or a scan failed), and a
child record `task/<id>/<what>` for each problem and for each ask that
didn't reach you as a message. An ask is `blocked` with `kind=question`; an
agent that stopped is `blocked`; a failure is `error`.
