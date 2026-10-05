# What run.sh and run_cluster.sh share: the paths, a controller's environment, the
# package, the runners, and the HTTP and stream helpers. Sourced, never run.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN=$(cd "$HERE/../.." && pwd)
CORE=$(cd "$PLUGIN/../.." && pwd)
REL=${FLEZHA_RELEASE:-$CORE/_build/prod/rel/flezha}
# A Unix socket path must fit in 108 bytes, so the directory stays short.
TMP=$(mktemp -d /tmp/flzhttp.XXXX)
GW=http://127.0.0.1:18080
FAILED=0
mkdir -p "$TMP/out"

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

say() { echo "[e2e] $*"; }
pass() { echo "PASS ($1) $2"; }
fail() { echo "FAIL ($1) $2"; FAILED=1; }

# Poll `command` every 0.1 s for up to `seconds`.
until_ok() {
  local n=$(($1 * 10))
  shift
  for _ in $(seq "$n"); do eval "$*" >/dev/null 2>&1 && return 0; sleep 0.1; done
  return 1
}

# `controller_env <dir> <node> <release>`: the environment `flz` and `flzvm` of
# one controller run in, its node name, state, plugin root, sockets and ports all
# its own under <dir>; authorization off, instances asleep after 5 s idle.
controller_env() {
  export PATH=$3/bin:$PATH
  export FLEZHA_CTL_DIR=$1/ctl
  export FLEZHA_SOCKET_FILES_PATH=$1/s
  export FLEZHA_NODE_NAME=$2
  export FLEZHA_STATE_DIR=$1/state
  export FLEZHA_PLUGIN_ROOT=$1/plugins
  export FLEZHA_AUTHZ_ENABLED=false
  export FLEZHA_DURABILITY_BACKEND=none
  FLEZHA_HEALTHZ_PORT=$(free_port) FLEZHA_PROMETHEUS_PORT=$(free_port) FLEZHA_TESTNET_WS_PORT=$(free_port)
  FLEZHA_QUIC_LISTEN_ADDRESS=127.0.0.1:$(free_port)
  export FLEZHA_HEALTHZ_PORT FLEZHA_PROMETHEUS_PORT FLEZHA_TESTNET_WS_PORT FLEZHA_QUIC_LISTEN_ADDRESS
  mkdir -p "$1/ctl" "$1/s"
}

# The release a run uses, and when it was built: it must be built from the core
# checkout as it is now, or every check reads an older controller.
say_release() {
  say "release $1, built $(date -r "$1/bin/flzvm" '+%Y-%m-%d %H:%M:%S')"
}

package_plugin() {
  say "packaging the plugin"
  (cd "$PLUGIN" && MIX_ENV=prod RUSTLER_SKIP_COMPILATION=true mix flezha.plugin.package --output "$TMP") \
    >"$TMP/out/package.log" 2>&1 || { cat "$TMP/out/package.log"; exit 1; }
}

# Install the package into the plugin root of the controller whose environment is set.
install_plugin() {
  (cd "$FLEZHA_CTL_DIR" && flz plugin install "$TMP/flezha_http-0.1.0.fpz") >>"$TMP/out/install.log" 2>&1 ||
    { cat "$TMP/out/install.log"; exit 1; }
}

start_controller() {
  (cd "$FLEZHA_CTL_DIR" && nohup flzvm start </dev/null >>"$TMP/out/controller-$FLEZHA_NODE_NAME.log" 2>&1 &)
  until_ok 90 "flz controller status" || { say "controller $FLEZHA_NODE_NAME did not come up"; exit 1; }
}

stop_controller() {
  (cd "$FLEZHA_CTL_DIR" && flzvm stop >/dev/null 2>&1)
  until_ok 30 "! pgrep -f 'beam.smp.* $FLEZHA_NODE_NAME@'" || pkill -KILL -f "beam.smp.* $FLEZHA_NODE_NAME@"
}

build_chat() {
  (cd "$HERE/chat" && mix deps.get && mix compile) >"$TMP/out/chat-build.log" 2>&1 ||
    { cat "$TMP/out/chat-build.log"; exit 1; }
}

# `start_runner <name> <namespace>`: the chat fixture as a runner of the
# controller whose environment is set, with a runner id of its own. Its standard
# input stays open until `stop_runner`, whose closing it reads as its stop.
start_runner() {
  mkfifo "$TMP/$1.in"
  (sleep infinity >"$TMP/$1.in" & echo $! >"$TMP/$1.hold")
  (cd "$HERE/chat" && FLEZHA_RUNNER_ID_PATH="$TMP/runner-id-$1" \
    setsid mix run --no-compile --no-deps-check --no-halt -- "$2" <"$TMP/$1.in" >"$TMP/out/$1.log" 2>&1 &
    echo $! >"$TMP/$1.pid")
}

stop_runner() {
  [ -f "$TMP/$1.pid" ] || return 0
  kill "$(cat "$TMP/$1.hold")" 2>/dev/null
  local pid
  pid=$(cat "$TMP/$1.pid")
  until_ok 10 "! kill -0 $pid" || kill -KILL -- "-$pid" 2>/dev/null
}

# `start_relay <factory> <id> [flags...]`, retried until a runner serves the
# factory; an attempt that started it but answered late is not started twice.
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

# The entry of one relay in `flz relay info --json`, as JSON.
relay_json() {
  flz relay info "$1" --json 2>/dev/null | python3 -c '
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
print(json.dumps(next(walk(json.load(sys.stdin)), {})))' "$1"
}

listeners() { relay_json "$1" | grep -o '"io_listener_' | wc -l; }

# End every stream this run opened.
stop_streams() {
  for pid in $(cat "$TMP"/*.stream 2>/dev/null); do kill "$pid" 2>/dev/null; done
}
