#!/usr/bin/env bash
# The plugin following its operator from one controller to another:
#
#   test/e2e/run_cluster.sh
#
# Two copies of the controller release on this host, each with its own node
# name, state root, plugin root and sockets, joined as one cluster the way the
# multi-node suite joins its peers: one shared cookie, and each node naming both
# in FLEZHA_INITIAL_NODES. The package is installed on both. `gateway` starts on
# controller A with the plugin on 18080; a stream is opened and a message posted;
# A is stopped with `flz controller stop`, whose drain moves the gateway (and the
# sessions) to B. The run checks that the stream through A ended, that B's worker
# now serves 18080, and that a new stream through B follows the same session
# through a turn it takes there. It prints PASS or FAIL per check, stops and removes everything it
# started, and exits non-zero on any FAIL.
#
# FLEZHA_RELEASE names the release, built from the core as it is now.
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
COOKIE=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
NODE_A=flzhttpa$$
NODE_B=flzhttpb$$

# `on <A|B> <command...>`: run in that controller's environment.
on() {
  local who=$1 node
  shift
  node=NODE_$who
  (
    controller_env "$TMP/$who" "${!node}" "$TMP/rel$who"
    export RELEASE_COOKIE=$COOKIE FLEZHA_INITIAL_NODES="$NODE_A@127.0.0.1,$NODE_B@127.0.0.1"
    "$@"
  )
}

stop_all() {
  stop_streams
  stop_runner runner_a
  stop_runner runner_b
  on B stop_controller
  on A stop_controller
  rm -rf "$TMP"
}
trap stop_all EXIT

gateway_node() {
  on "${1:-B}" flz operator list --json 2>/dev/null | python3 -c '
import json, sys
print(next((o.get("node", "") for o in json.load(sys.stdin).get("operators", []) if o.get("id") == "gateway"), ""))'
}

say_release "$REL"
say "copying the release twice"
cp -a "$REL" "$TMP/relA"
cp -a "$REL" "$TMP/relB"
package_plugin
on A install_plugin
on B install_plugin

say "starting controllers A and B as one cluster"
on A start_controller
on B start_controller
until_ok 60 "on A flzvm rpc 'IO.puts(Enum.member?(Node.list(), :\"$NODE_B@127.0.0.1\"))' | grep -q true" ||
  { say "B did not join A"; exit 1; }

say "the gateway on A"
build_chat
on A start_runner runner_a default
web='[{"id":"web","provider":"http_server","hooks":["on_terminate"],"opts":{"port":"18080","channel":"http","pass_headers":"x-api-key","heartbeat_ms":"1000"}}]'
on A start_operator gateway gateway --plugins "$web"
until_ok 30 "curl -s -o /dev/null $GW/no-route" || { say "nothing listens on 18080"; exit 1; }
before=$(gateway_node A)

session=$(open_session anna)
stream a "/sessions/$session/events?user=anna"
stream_open a
message anna "$session" "before the move" >/dev/null
until_ok 10 "[ \$(events a output) -ge 1 ]"

say "a runner on B, then A stopped"
on B start_runner runner_b default
until_ok 60 "[ \$(on B flz runner list 2>/dev/null | grep -c ' default_') -ge 2 ]" ||
  { say "the runner on B did not connect"; exit 1; }
# A drain hands over only to a node its namespace hub already counts.
until_ok 60 "on A flzvm rpc 'IO.inspect(Flezha.Cluster.Directory.hub_nodes(\"default\"))' | grep -q '$NODE_B'" ||
  { say "B never joined the namespace hub"; exit 1; }
on A flz controller stop >"$TMP/out/stop-a.log" 2>&1
# The stop ends A's VM itself once its drain has handed the operators over.
until_ok 60 "! pgrep -f 'beam.smp.* $NODE_A@'" || say "A is still running after its stop"

if until_ok 10 "! kill -0 $(cat "$TMP/a.stream")"; then
  pass 1 "the stream through A ended ($(grep -c '^event: closed' "$TMP/out/a.events") closed events)"
else
  fail 1 "the stream through A is still open"
fi

if until_ok 60 "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $GW/no-route -m 1)\" = 404 ]" &&
  [ "$(gateway_node)" = "$NODE_B@127.0.0.1" ]; then
  pass 2 "18080 is served again, by the gateway now on B (it was on $before)"
else
  fail 2 "18080 answers $(curl -s -o /dev/null -w '%{http_code}' $GW/no-route -m 1); gateway on '$(gateway_node)' (was '$before')"
  grep -hiE "drain|serialize|handover" "$TMP/A/ctl/logs/flezha.log" | tail -8 | cut -c1-300
  grep -hiE "gateway|handover|restor" "$TMP/B/ctl/logs/flezha.log" | tail -8 | cut -c1-300
fi

# The session is streamed through B's server and handed a turn on B directly:
# the gateway's own keyed state does not survive the move (see the dev note).
stream b "/raw/$session/events"
if stream_open b 10 && on B flz operator send "$session" --channel turn --text '{"text":"after the move"}' >/dev/null &&
  until_ok 20 "[ \$(events b output) -ge 1 ]" && [ "$(payloads b part | tr '\n' ' ')" = "after the move " ]; then
  pass 3 "a new stream through B follows $session, which moved with it and turned again"
else
  fail 3 "stream: $(tr '\n' ' ' <"$TMP/out/b.events" | head -c 300)"
fi

exit $FAILED
