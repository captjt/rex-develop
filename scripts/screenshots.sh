#!/bin/bash
# Render the README's screenshots and the social preview card from a made-up
# world, so nothing of yours shows up in them: a rex-develop session whose
# watcher has asked you about four issues of a made-up Linear team, ENG, in
# a made-up repo, acme/api.
#
# The pictures are rex-inbox's own Mac panel and phone app, which is where
# you meet rex-develop. They come from a rex-inbox checkout with answer
# options on messages (REX_INBOX_DIR, ../rex-inbox by default): its hub
# follows the world through its scripts/fake-rex, with a state folder,
# socket and port of its own, so your own Rex, hub and inbox are left alone.
# The messages are made by rex-develop's own code (scripts/shots-messages.lua).
#
# Needs a Rust toolchain, Swift 6, jq, sqlite3, luajit, Node 22 or later, and
# Google Chrome. Upload docs/images/social-preview.png in the repo's
# Settings, under Social preview.
#
#   scripts/screenshots.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
images="$root/docs/images"
inbox_dir=$(cd "${REX_INBOX_DIR:-$root/../rex-inbox}" && pwd)
demo=$(mktemp -d)
sock="/tmp/rex-develop-shots-$$.sock"
port=7449
hub=""
cleanup() {
  [ -n "$hub" ] && kill "$hub" 2>/dev/null || true
  rm -rf "$demo" "$sock"
}
trap cleanup EXIT

cargo build --release --quiet --manifest-path "$inbox_dir/Cargo.toml"
inbox="$inbox_dir/target/release/rex-inbox"
if ! "$inbox" send --help | grep -q -- --option; then
  echo "$inbox_dir has no answer options on messages; point REX_INBOX_DIR at a rex-inbox that does" >&2
  exit 1
fi
swift build -c release --package-path "$inbox_dir/mac" >/dev/null
app="$(swift build -c release --package-path "$inbox_dir/mac" --show-bin-path)/RexInbox"
mkdir -p "$images"

# --- The world ---------------------------------------------------------------

jq -n --arg home "$HOME" --arg api "$HOME/code/api" '
def ago($m): (now - $m * 60) | floor | todate;
def pane($label; $process; $records): {block_id: "block:\($label)", label: $label, cwd: $api, process: $process, records: $records};
def root($state; $app; $m): {state: $state, app: $app, updated_at: ago($m)};
{
  home: $home,
  sessions: [
    {session_id: "session:rex-develop", label: "rex-develop", windows: [
      {window_id: "window:control", label: "control", blocks: [
        pane("watcher"; "luajit"; [root("idle"; "rex-develop"; 1)]) + {cwd: $home}
      ]},
      {window_id: "window:eng-142", label: "eng-142", blocks: [
        pane("eng-142"; "claude"; [root("idle"; "claude-code"; 2)])
      ]},
      {window_id: "window:eng-138", label: "eng-138", blocks: [
        pane("eng-138"; "claude"; [root("idle"; "claude-code"; 11)])
      ]},
      {window_id: "window:eng-145", label: "eng-145", blocks: [
        pane("eng-145"; "claude"; [root("working"; "claude-code"; 1) + {msg: "Building: paginate the audit log"}]),
        pane("eng-145-check"; "codex"; [root("working"; "codex"; 1) + {msg: "Checking the branch against the plan"}])
      ]}
    ]}
  ]
}' >"$demo/world.json"

# --- The hub, following the world --------------------------------------------

export REX_INBOX_STATE="$demo/state" REX_INBOX_SOCKET="$sock"
REX_INBOX_REX="$inbox_dir/scripts/fake-rex" REX_INBOX_WORLD="$demo/world.json" REX_REVIEWER_STATE_DIR="$demo/no-reviewer" \
  REX_INBOX_HTTP="127.0.0.1:$port" REX_INBOX_WEB_DEV=1 REX_INBOX_NOTIFY=off REX_INBOX_TAILSCALE=/usr/bin/false \
  "$inbox" hub >"$demo/hub.log" 2>&1 &
hub=$!
disown "$hub"

# The watcher's messages, oldest first, each sent from its pane. The first
# waits for the hub to see the pane, and that it's rex-develop's.
db="$demo/state/inbox.db"
luajit "$root/scripts/shots-messages.lua" | jq -c '.[]' | while read -r m; do
  args=(send --to me --subject "$(jq -r .subject <<<"$m")")
  while read -r o; do args+=(--option "$o"); done < <(jq -r '.options // [] | .[]' <<<"$m")
  args+=(-)
  sent=""
  for _ in $(seq 1 50); do
    if sent=$(jq -r .body <<<"$m" | REX_SESSION=session:rex-develop REX_BLOCK=block:watcher "$inbox" "${args[@]}" 2>/dev/null); then
      break
    fi
    sleep 0.2
  done
  id=$(grep -o '#[0-9]*' <<<"$sent" | head -1 | tr -d '#')
  [ -n "$id" ] || { echo "the hub never took a message: $(tail -5 "$demo/hub.log")" >&2; exit 1; }
  sqlite3 "$db" "UPDATE messages SET created_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$(jq -r .minutes <<<"$m") minutes') WHERE id = $id;"
done

# --- The screenshots ---------------------------------------------------------

for look in light dark; do
  "$app" --snapshot "$images/inbox-$look.png" --appearance "$look"
  node "$inbox_dir/scripts/phone-shot.mjs" "http://127.0.0.1:$port/" "$images/phone-$look.png" "$look"
done
echo "wrote $images/{inbox,phone}-{light,dark}.png"

# The social preview card shows inbox-dark.png, so render it again too.
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$chrome" --headless=new --disable-gpu --hide-scrollbars --window-size=1280,640 \
  --screenshot="$images/social-preview.png" "file://$images/social-preview.html" >/dev/null 2>&1
echo "wrote $images/social-preview.png"
