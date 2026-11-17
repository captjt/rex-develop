#!/usr/bin/env bash
# A stand-in for Claude Code or Codex as rex-develop's builder or checker,
# for tests/e2e.sh. It reports program status (OSC 7501) as they do, reads
# each prompt (a burst of lines), and does what the prompt asks with made-up
# work in its worktree. The issue's text steers it:
#
#   [fake: fix first]   the first check finds a blocking problem
#   [fake: preview]     the build leaves a preview (no port)
#
# Whatever arguments it's started with are ignored.

osc() { printf '\033]7501;%s\033\\' "$1"; }
app=fake-agent
status() { printf '%s\n' "$1" >.tmp/status.txt; }
issue_says() { grep -qF "$1" .tmp/context/issue.md 2>/dev/null; }

plan() {
	cat >.tmp/plan.md <<'EOF'
# Plan: retry failed webhook deliveries

## Intent
Failed webhook deliveries retry with backoff, so a receiver's short outage no longer drops events.

## Acceptance
- A failed delivery retries: `feature.txt` says how.

## Decisions
- D1: Should retries cover 4xx responses? Recommended: 5xx and timeouts only.

## Approach
1. Write feature.txt.

## Out of scope
- A dead-letter queue.

## Notes
- Backoff doubles; that's the convention here.
EOF
	mkdir -p .tmp/decisions
	cat >.tmp/decisions/D1.json <<'EOF'
{
  "id": "D1",
  "question": "Should retries cover 4xx responses?",
  "why": "The issue says retry failed deliveries, and a 4xx is a failure too.",
  "options": [
    { "label": "5xx and timeouts only", "detail": "Rejected payloads fail at once." },
    { "label": "Every non-2xx", "detail": "Simpler, but a bad payload is sent again." }
  ],
  "recommend": 0,
  "mode": "provisional",
  "meanwhile": "Planning on 5xx and timeouts only."
}
EOF
	status PLAN_READY
}

build() {
	local choice
	choice=$(sed -n 's/.*"label": *"\([^"]*\)".*/\1/p' .tmp/decisions/D1.answer.json 2>/dev/null | head -1)
	printf 'retries: %s\n' "${choice:-unknown}" >feature.txt
	git add feature.txt
	git commit -q -m "feat(webhooks): retry failed deliveries"
	# The wall: a push from here must fail.
	if git push -q origin HEAD 2>/dev/null; then echo pushed >.tmp/push-attempt.txt; else echo failed >.tmp/push-attempt.txt; fi
	cat >.tmp/pr.json <<'EOF'
{ "title": "feat(webhooks): retry failed deliveries", "body": "Deliveries that fail are retried.\n\n## What changes\n\n- `feature.txt` says what retries.\n\n## Testing\n\n- Looked at it." }
EOF
	echo "built; feature.txt has the choice" >.tmp/report.md
	if issue_says "[fake: preview]"; then
		printf '{ "title": "The retry log", "ask": "Does the log read right?", "what": "retries: 3 attempts" }\n' >.tmp/preview.json
	fi
	touch .tmp/.fake-built
	status BUILT
}

fix() {
	echo "fixed: $1" >>feature.txt
	git add feature.txt
	git commit -q -m "fix(webhooks): $1"
	status BUILT
}

check() {
	local n=$1 verdict=pass findings='[]'
	if [[ $n == 1 ]] && issue_says "[fake: fix first]"; then
		verdict=fix
		findings='[{ "id": "F1", "severity": "blocking", "what": "No backoff.", "where": "feature.txt:1", "evidence": "cat feature.txt", "fix": "Add backoff." }]'
	fi
	mkdir -p .tmp/check
	printf '{ "verdict": "%s", "summary": "Check %s: %s.", "findings": %s }\n' "$verdict" "$n" "$verdict" "$findings" >".tmp/check/check-$n.json"
	echo "check $n: $verdict" >".tmp/check/report-$n.md"
	echo CHECKED >.tmp/checker-status.txt
}

handle() {
	local text=$1 n
	osc "state=working:app=$app"
	echo "fake-agent: $(head -1 <<<"$text")"
	sleep "${FAKE_WORK:-1}"
	case $text in
	*"This is check "*)
		n=$(grep -o 'This is check [0-9]*' <<<"$text" | grep -o '[0-9]*$' | tail -1)
		check "$n"
		;;
	*".tmp/tasks/plan.md, and do the task"* | *"Proceed: plan"* | *"Revise the plan"*) plan ;;
	*"The plan is approved"*) build ;;
	*"The checker found problems"*) fix "add backoff" ;;
	*"needs changes"* | *"preview needs work"*) fix "as asked" ;;
	*)
		# An update while building or planning: carry on to the same end.
		if [[ -e .tmp/.fake-built ]]; then status BUILT; else status PLAN_READY; fi
		;;
	esac
	osc "state=idle:app=$app"
	echo "fake-agent: done"
}

sleep "${FAKE_BOOT:-1}"
osc "state=idle:app=$app"
echo "fake-agent: ready in $PWD"

# Each burst of lines is one prompt. macOS's bash 3.2 returns 1 when read
# times out (newer bash returns more than 128), so a closed stdin is told
# apart by time: a timeout takes a second, and end of input takes none.
buf=""
fails=0
t0=$SECONDS
while :; do
	rc=0
	line=""
	IFS= read -r -t 1 line || rc=$?
	if ((rc == 0)); then
		buf+="$line"$'\n'
		continue
	fi
	[[ -n ${line:-} ]] && buf+="$line"
	if [[ -n $buf ]]; then
		handle "$buf"
		buf=""
	fi
	if ((SECONDS == t0)); then
		fails=$((fails + 1))
		((fails > 20)) && exit 0
	else
		fails=0
		t0=$SECONDS
	fi
done
