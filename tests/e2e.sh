#!/usr/bin/env bash
# An end-to-end run in Rex, with no tokens and nothing real: a made-up
# Linear (tests/fake-linear.py), a stand-in agent (tests/fake-agent.sh), a
# stand-in gh (tests/bin/gh), and a local bare repo as origin. It starts a
# watcher in its own Rex session, answers what it asks the way you would,
# and checks what lands. Needs Rex, luajit, jq, git, and python3.
#
#   tests/e2e.sh            keep the folder only when it fails
#   KEEP=1 tests/e2e.sh     keep it either way
#   INBOX=1 tests/e2e.sh    reach "you" through a rex-inbox hub of its own,
#                           and answer with rex-inbox reply, as its buttons do.
#                           REX_INBOX_BIN names the rex-inbox to use; it needs
#                           answer options on messages. Your own inbox is
#                           never touched.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/rex-develop-e2e.XXXXXX")
export REX_DEVELOP_CONFIG_DIR=$T/config REX_DEVELOP_STATE_DIR=$T/state REX_DEVELOP_DATA_DIR=$T/data REX_DEVELOP_CACHE_DIR=$T/cache
SESSION=rex-develop-e2e
RD=("$ROOT/bin/rex-develop")
INBOX=${INBOX:-0}
RI=${REX_INBOX_BIN:-rex-inbox}
pass=0
fail=0
server_pid=""
hub_pid=""

say() { printf '\n== %s\n' "$*"; }
ok() {
	pass=$((pass + 1))
	printf 'ok   %s\n' "$1"
}
bad() {
	fail=$((fail + 1))
	printf 'FAIL %s\n' "$1"
}
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

cleanup() {
	set +e
	"${RD[@]}" down >/dev/null 2>&1
	sid=$(jq -r '.session_id // empty' "$T/state/state.json" 2>/dev/null)
	[[ -n $sid ]] && rex session kill "$sid" >/dev/null 2>&1
	[[ -n $server_pid ]] && kill "$server_pid" 2>/dev/null
	[[ -n $hub_pid ]] && kill "$hub_pid" 2>/dev/null
	if [[ ${KEEP:-} == 1 || $fail -gt 0 ]]; then
		echo "kept $T"
	else
		rm -rf "$T"
	fi
}
trap cleanup EXIT

status_json() { "${RD[@]}" do develop_status; }

# The rex-inbox message an ask went out as.
msg_id() { "${RD[@]}" do develop_asks | jq -r --arg k "$1" --arg w "$2" '.[] | select(.task == $k and .what == $w) | .message_id // empty'; }

# Answer an ask the way you would: with rex-inbox's reply (a button, and any
# words), or with rex-develop's CLI.
answer() {
	local key=$1 what=$2 choice=$3 text=${4:-} id
	if [[ $INBOX == 1 ]]; then
		id=$(msg_id "$key" "$what")
		if [[ -z $id ]]; then
			bad "answer $key $what: no message for it"
			return
		fi
		"$RI" reply "$id" --as-me --choice "$choice" ${text:+"$text"} >/dev/null || bad "answer $key $what $choice"
	else
		"${RD[@]}" answer "$key" "$what" "$choice" ${text:+"$text"} >/dev/null || bad "answer $key $what $choice"
	fi
}

# Wait until a shell test holds.
wait_for() {
	local desc=$1 cond=$2 limit=${3:-60} start=$SECONDS
	while ((SECONDS - start < limit)); do
		if eval "$cond"; then
			ok "$desc"
			return
		fi
		sleep 2
	done
	bad "$desc"
}
to_me() { "$RI" inbox --as-me --all --json | jq -c '(.messages? // .)[]'; }
task() { status_json | jq -c --arg k "$1" '.tasks[] | select(.key == $k)'; }

# Wait until a jq test on the task holds, or give up after $3 seconds.
wait_task() {
	local key=$1 test=$2 limit=${3:-120} start=$SECONDS
	while ((SECONDS - start < limit)); do
		if task "$key" | jq -e "$test" >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
	done
	echo "  timed out waiting for $key: $test"
	echo "  task now: $(task "$key")"
	echo "  watcher: $(jq -c . "$T/state/watcher.json" 2>/dev/null)"
	return 1
}

say "a made-up world in $T"
mkdir -p "$T/config" "$T/gh"
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/checkout" 2>/dev/null
git -C "$T/checkout" config user.name "Test"
git -C "$T/checkout" config user.email "test@example.com"
echo "# demo" >"$T/checkout/README.md"
git -C "$T/checkout" add README.md
git -C "$T/checkout" commit -q -m "chore: start"
git -C "$T/checkout" push -q origin main
git -C "$T/checkout" remote set-head origin main

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
cat >"$T/linear.json" <<'EOF'
{
  "viewer": { "id": "me", "name": "Sam" },
  "issues": [
    { "id": "i142", "identifier": "ENG-142", "title": "Retry failed webhook deliveries",
      "url": "https://linear.app/acme/issue/ENG-142", "branchName": "sam/eng-142-retry-failed-webhooks", "priority": 2,
      "state": { "name": "Todo", "type": "unstarted" }, "assignee": { "id": "me" },
      "labels": ["agent"], "cycle": null, "team": "ENG",
      "description": "Deliveries that fail are lost. Retry them. [fake: fix first] [fake: preview]",
      "comments": [{ "body": "429s count too?", "user": "Lee" }] },
    { "id": "i150", "identifier": "ENG-150", "title": "Dead-letter queue",
      "url": "https://linear.app/acme/issue/ENG-150", "branchName": "sam/eng-150-dead-letter-queue", "priority": 3,
      "state": { "name": "Todo", "type": "unstarted" }, "assignee": { "id": "me" },
      "labels": [], "cycle": { "id": "c9", "number": 9, "isActive": true }, "team": "ENG",
      "description": "Keep what never delivers.", "comments": [] }
  ]
}
EOF
python3 "$ROOT/tests/fake-linear.py" "$port" "$T/linear.json" &
server_pid=$!

if [[ $INBOX == 1 ]]; then
	RI=$(command -v "$RI") || {
		echo "no rex-inbox at ${REX_INBOX_BIN:-rex-inbox}"
		exit 1
	}
	mkdir -p "$T/bin"
	ln -s "$RI" "$T/bin/rex-inbox"
	export REX_INBOX_SOCKET=$T/inbox.sock REX_INBOX_STATE=$T/inbox
	REX_INBOX_HTTP=off REX_INBOX_NOTIFY=off "$RI" hub >"$T/hub.log" 2>&1 &
	hub_pid=$!
	for _ in $(seq 40); do
		"$RI" status >/dev/null 2>&1 && break
		sleep 0.5
	done
	"$RI" status >/dev/null 2>&1 || {
		echo "the test's rex-inbox hub didn't start: $(tail -5 "$T/hub.log")"
		exit 1
	}
fi

cat >"$T/config/config.lua" <<EOF
return {
  session = "$SESSION",
  trackers = {
    linear = { label = "agent", cycle = true, teams = { ENG = "acme/demo" },
      endpoint = "http://127.0.0.1:$port/graphql", key = "test-key" },
  },
  repos = { ["acme/demo"] = { checkout = "$T/checkout", base = "main", notes = "There's nothing to build." } },
  builder = "claude",
  checker = "claude",
  agents = { claude = { program = "$ROOT/tests/fake-agent.sh" } },
  inbox = $([[ $INBOX == 1 ]] && echo true || echo false),
  poll_seconds = 30,
  fix_loops = 1,
  path = { "$ROOT/tests/bin", "$T/bin" },
}
EOF
sleep 1

say "a dry scan sees both issues"
scan=$("${RD[@]}" scan)
check "the labeled issue queues" '[[ $(jq -r "[.events[] | select(.task == \"ENG-142\")][0].kind" <<<"$scan") == queued ]]'
check "the cycle issue is offered" '[[ $(jq -r "[.events[] | select(.task == \"ENG-150\")][0].kind" <<<"$scan") == offered ]]'

say "the watcher starts in its own session"
"${RD[@]}" up >/dev/null
check "the session exists" 'rex session ls --json 2>/dev/null | jq -e --arg s "$SESSION" "[.. | objects | select(.label? == \$s)] | length > 0" >/dev/null'

say "ENG-142: the plan, with a decision"
wait_task ENG-142 '.state == "active" and .phase == "plan_gate" and (.asks | index("plan")) and (.asks | index("D1"))' 120 &&
	ok "the plan and D1 wait on you" || bad "the plan and D1 wait on you"
wait_task ENG-150 '.state == "offered" and (.asks | index("start"))' 30 &&
	ok "ENG-150 asks whether to start" || bad "ENG-150 asks whether to start"
asks=$("${RD[@]}" do develop_asks)
check "the decision's buttons are its options" '[[ $(jq -r ".[] | select(.what == \"D1\") | .options | join(\"|\")" <<<"$asks") == "5xx and timeouts only|Every non-2xx" ]]'
check "the plan's subject counts what's open" 'jq -r ".[] | select(.what == \"plan\") | .subject" <<<"$asks" | grep -q "1 acceptance item, 1 decision open"'

if [[ $INBOX == 1 ]]; then
	say "through rex-inbox"
	d1=$(msg_id ENG-142 D1)
	check "D1 went out as a message" '[[ -n $d1 ]]'
	m=$("$RI" read "$d1" --as-me --json)
	check "with its options as buttons" '[[ $(jq -r ".message.options | join(\"|\")" <<<"$m") == "5xx and timeouts only|Every non-2xx" ]]'
	check "from the watcher's pane, not from you" '[[ $(jq -r .message.from_addr <<<"$m") != me ]]'
	check "the plan went out too" '[[ -n $(msg_id ENG-142 plan) ]]'
	check "so did ENG-150's start" '[[ -n $(msg_id ENG-150 start) ]]'
	check "nothing waits only as a status record" '[[ $(jq "[.waiting[] | select(.message_id == null)] | length" "$T/state/watcher.json") == 0 ]]'
fi

say "answers"
answer ENG-150 start Skip
wait_task ENG-150 '.state == "skipped"' 30 && ok "Skip skips it" || bad "Skip skips it"
answer ENG-142 D1 "Every non-2xx" "but cap it at 3"
wait_task ENG-142 '(.asks | index("D1")) | not' 30 && ok "D1 is answered" || bad "D1 is answered"
if [[ $INBOX == 1 ]]; then
	"$RI" reply "$d1" --as-me --choice "5xx and timeouts only" >/dev/null
	wait_for "a late answer is told it's too late" 'to_me | jq -e "select(.body | test(\"already has its answer\"))" >/dev/null' 30
	check "and changes nothing" 'grep -q "Every non-2xx" "$T/data/worktrees/linear-ENG-142/.tmp/decisions/D1.answer.json"'
else
	check "a stale answer is refused" '! "${RD[@]}" answer ENG-142 D1 1 >/dev/null 2>&1'
fi
answer ENG-142 plan Approve

say "build, check, fix, check again, preview"
wait_task ENG-142 '.phase == "preview_gate" and (.asks | index("preview"))' 180 &&
	ok "after a fix round, the preview waits on you" || bad "after a fix round, the preview waits on you"
WT=$T/data/worktrees/linear-ENG-142
check "check 1 asked for a fix" 'grep -q "\"verdict\": \"fix\"" "$WT/.tmp/check/check-1.json"'
check "check 2 passed" 'grep -q "\"verdict\": \"pass\"" "$WT/.tmp/check/check-2.json"'
check "the builder followed D1" 'grep -q "retries: Every non-2xx" "$WT/feature.txt"'
check "the agent could not push" '[[ $(cat "$WT/.tmp/push-attempt.txt") == failed ]]'
check "the D1 answer file has the note" 'grep -q "but cap it at 3" "$WT/.tmp/decisions/D1.answer.json"'
check "nothing reached origin yet" '! git -C "$T/origin.git" rev-parse --verify -q refs/heads/sam/eng-142-retry-failed-webhooks >/dev/null'
answer ENG-142 preview "Looks right"

say "open"
wait_task ENG-142 '.phase == "open_gate" and (.asks | index("open"))' 60 && ok "the PR waits on you" || bad "the PR waits on you"
answer ENG-142 open "Open PR"
wait_task ENG-142 '.state == "open" and .pr != null' 60 && ok "the PR opened" || bad "the PR opened"
BODY=$T/gh/pr-body.md
check "it was pushed to origin" 'git -C "$T/origin.git" rev-parse --verify -q refs/heads/sam/eng-142-retry-failed-webhooks >/dev/null'
check "with both commits" '[[ $(git -C "$T/origin.git" rev-list --count main..sam/eng-142-retry-failed-webhooks) == 2 ]]'
check "as a draft" 'grep -qx -- "--draft" "$T/gh/pr-args.txt"'
check "the body closes the issue" 'grep -q "^Closes ENG-142" "$BODY"'
check "the body has the plan" 'grep -q "<!-- rex-develop:plan v1 ENG-142 -->" "$BODY"'
check "the plan says who decided D1, and how" 'grep -qF "Every non-2xx. Chosen by @tester: \"but cap it at 3\"." "$BODY"'
check "the plan says who approved it" 'grep -qF "approved by @tester" "$BODY"'
check "the footer names the agents" 'grep -qF "on behalf of @tester · checked by" "$BODY"'
check "nothing from .tmp shipped" '[[ -z $(git -C "$T/origin.git" ls-tree -r --name-only sam/eng-142-retry-failed-webhooks | grep "^.tmp/") ]]'
check "the agents' panes closed" '! "$ROOT/bin/rex-agent" get eng-142 -s "$(jq -r .session_id "$T/state/state.json")" >/dev/null 2>&1'

if [[ $INBOX == 1 ]]; then
	wait_for "you hear that it opened" 'to_me | jq -e "select(.subject | test(\"opened\"))" >/dev/null' 30
fi

say "merged"
echo MERGED >"$T/gh/pr-state"
"${RD[@]}" check >/dev/null
wait_task ENG-142 '.state == "merged"' 60 && ok "a merged PR ends the task" || bad "a merged PR ends the task"
check "its worktree is gone" '[[ ! -e $WT ]]'
check "its local branch is gone" '! git -C "$T/checkout" rev-parse --verify -q refs/heads/sam/eng-142-retry-failed-webhooks >/dev/null'

printf '\ne2e: %d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
