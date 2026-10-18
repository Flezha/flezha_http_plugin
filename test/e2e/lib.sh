# What run.sh and run_cluster.sh share: the plugin e2e library, and the HTTP and
# stream helpers. Sourced, never run.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN=$(cd "$HERE/../.." && pwd)
CORE=$(cd "$PLUGIN/../.." && pwd)
REL=${FLEZHA_RELEASE:-$CORE/_build/prod/rel/flezha}
PACKAGE=flezha_http
TMP_PREFIX=flzhttp
RUNNER_DIR=chat
POLL_TENTHS=1
AWAIT_PACKAGE=no
# shellcheck source=../../../../test/helpers/plugin_e2e.sh
. "$CORE/test/helpers/plugin_e2e.sh"
GW=http://127.0.0.1:18080

# Instances keep no durable state here.
plugin_env() { export FLEZHA_DURABILITY_BACKEND=none; }

# The library's `start_relay`, taking flags: `start_relay <factory> <id> [flags...]`,
# retried until a runner serves the factory; an attempt that started it but
# answered late is not started twice.
start_relay() {
  local id=$2 args=(relay start "$1" --id "$2")
  shift 2
  args+=("$@")
  for _ in $(seq 60); do
    flz "${args[@]}" >>"$TMP/out/start-$id.log" 2>&1 && return 0
    [ "$(relay_json "$id")" != "{}" ] && return 0
    sleep 1
  done
  say "$id did not start: $(tail -3 "$TMP/out/start-$id.log")"
  exit 1
}

# `http <name> <curl args...>`: the status, with the body in $TMP/out/<name>.body
# and the headers in $TMP/out/<name>.head.
http() {
  local name=$1
  shift
  curl -s -o "$TMP/out/$name.body" -D "$TMP/out/$name.head" -w '%{http_code}' "$@"
}

# A session of `user`, opened with POST /sessions.
open_session() {
  http "open-$1" -X POST "$GW/sessions?user=$1" >/dev/null
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["session"])' "$TMP/out/open-$1.body"
}

# `stream <name> <path>`: a background `curl -N` writing to $TMP/out/<name>.events.
stream() {
  curl -sN "$GW$2" >"$TMP/out/$1.events" 2>&1 &
  echo $! >"$TMP/$1.stream"
}

stream_open() { until_ok "${2:-5}" "grep -q '^:' $TMP/out/$1.events"; }
events() { grep -c "^event: $2" "$TMP/out/$1.events"; }

message() { # user session text [extra curl args]
  local user=$1 session=$2 text=$3
  shift 3
  http "msg-$user" -X POST "$GW/sessions/$session/messages?user=$user" -H 'x-api-key: test-key' \
    -d "{\"text\":\"$text\"}" "$@"
}

# The `data:` payloads of one event name, one per line.
payloads() {
  python3 - "$TMP/out/$1.events" "$2" <<'PY'
import json, sys
name = None
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if line.startswith("event: "):
        name = line[7:]
    elif line.startswith("data: ") and name == sys.argv[2]:
        print(json.loads(line[6:]).get("payload", ""))
PY
}

# The entry of one relay in `flz relay info --json`, as JSON; `{}` for a relay
# that is not running. Named, `relay info` shows the relay's API instead.
relay_json() {
  flz relay info --json 2>/dev/null | python3 -c '
import json, sys
def walk(node):
    if isinstance(node, dict):
        if node.get("id") == sys.argv[1] and "plugins" in node:
            yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)
print(json.dumps(next(walk(json.loads(sys.stdin.read() or "{}")), {})))' "$1"
}

listeners() { relay_json "$1" | grep -o '"io_listener_' | wc -l; }

# End every stream this run opened.
stop_streams() {
  for pid in $(cat "$TMP"/*.stream 2>/dev/null); do kill "$pid" 2>/dev/null; done
}
