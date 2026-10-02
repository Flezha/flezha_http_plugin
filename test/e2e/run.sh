#!/usr/bin/env bash
# The plugin end to end, against a real controller release:
#
#   test/e2e/run.sh            every check
#   test/e2e/run.sh b g h      only those checks (the setup they share still runs)
#
# It packages the plugin, installs it into the release under a temporary plugin
# root, starts the controller (its state, sockets and node name its own), the
# chat fixture's runner in `default` and a second one in `other`, starts
# `gateway` with the plugin on 18080 and `pinger` with it on 18081, runs the
# checks, prints PASS or FAIL for each, and stops and removes everything it
# started. It exits non-zero on any FAIL.
#
# FLEZHA_RELEASE names the release (default: the core checkout's prod release),
# which must be built from the core as it is now; the run prints its path and
# build time first.
# FLEZHA_E2E_TIMING=1 adds the stream-open timing (20 opens, mean and maximum).
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

stop_all() {
  stop_streams
  stop_runner runner
  stop_runner runner_other
  stop_controller
  rm -rf "$TMP"
}

setup() {
  say_release "$REL"
  package_plugin
  install_plugin
  say "starting the controller"
  start_controller
  flz namespace create other >/dev/null 2>&1

  say "building and starting the chat runners"
  build_chat
  start_runner runner default
  start_runner runner_other other

  local web='[{"name":"web","provider":"http_server","hooks":["on_terminate"],"opts":{"port":"18080","channel":"http","pass_headers":"x-api-key","heartbeat_ms":"1000","deadline_ms":"2000","stream_wait_ms":"3000","max_body_bytes":"4096"}}]'
  local ping='[{"name":"ping","provider":"http_server","hooks":["on_terminate"],"opts":{"port":"18081","channel":"http"}}]'
  start_operator gateway gateway --plugins "$web"
  start_operator pinger pinger --plugins "$ping"
  until_ok 30 "curl -s -o /dev/null $GW/nothing-here" || { say "nothing listens on 18080"; exit 1; }
}

# ---------- checks ----------

check_a() {
  local status
  status=$(http a -X POST "$GW/sessions?user=anna")
  if [ "$status" = 201 ] && grep -q '"session":"anna-' "$TMP/out/a.body"; then
    pass a "POST /sessions gives 201 and $(cat "$TMP/out/a.body")"
  else
    fail a "POST /sessions gave $status $(cat "$TMP/out/a.body")"
  fi
}

check_b() {
  local session words="one two three four five six seven eight nine ten eleven twelve" status took
  session=$(open_session bea)
  stream b "/sessions/$session/events?user=bea"
  stream_open b || { fail b "the stream did not open"; return; }
  took=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' -X POST "$GW/sessions/$session/messages?user=bea" \
    -H 'x-api-key: test-key' -d "{\"text\":\"$words\"}")
  until_ok 10 "[ \$(events b output) -ge 2 ]"
  status=${took% *}
  local parts output
  parts=$(payloads b part | tail -12 | tr '\n' ' ')
  output=$(awk '/^event: part/{p=NR} /^event: output/{o=NR} END{print (o>p)}' "$TMP/out/b.events")
  if [ "$status" = 202 ] && python3 -c "import sys; sys.exit(0 if float('${took#* }') < 0.5 else 1)" &&
    [ "$parts" = "$words " ] && [ "$output" = 1 ]; then
    pass b "202 in ${took#* } s; parts in order, then the output"
  else
    fail b "status $status in ${took#* } s; parts '$parts'; output after parts: $output"
  fi
}

check_c() {
  local session status n=0
  session=$(open_session carl)
  stream c "/sessions/$session/events?user=carl"
  stream_open c
  while [ $n -lt 8 ]; do
    status=$(message carl "$session" "a b c d e f g h i j")
    [ "$status" = 429 ] && break
    n=$((n + 1))
    until_ok 10 "[ \$(events c output) -ge $((n + 1)) ]"
    sleep 0.3
  done
  if [ "$status" = 429 ] && grep -qi '^retry-after: 3600' "$TMP/out/msg-carl.head"; then
    pass c "429 with retry-after after $n messages of 10 tokens"
  else
    fail c "no 429 after $n messages (last $status)"
  fi
}

check_d() {
  local session status
  session=$(open_session dora)
  status=$(http d -X POST "$GW/sessions/$session/messages?user=dora" -d '{"text":"hi"}')
  flz operator listen gateway --input --json --duration-ms 4000 >"$TMP/out/d.listen" 2>&1 &
  local listener=$!
  until_ok 5 "[ \$(listeners gateway) -ge 1 ]"
  message dora "$session" "hi" -H 'authorization: Bearer secret-token' >/dev/null
  wait $listener
  if [ "$status" = 401 ] && grep -q 'x-api-key' "$TMP/out/d.listen" && ! grep -qi 'authorization\|secret-token' "$TMP/out/d.listen"; then
    pass d "no key gives 401; the input carries x-api-key and not authorization"
  else
    fail d "status $status; listen output: $(head -c 400 "$TMP/out/d.listen")"
  fi
}

check_e() {
  local out
  out=$(curl -s -o "$TMP/out/e.body" -w '%{http_code} %{time_total}' "$GW/nothing")
  if [ "${out% *}" = 504 ] && grep -q '"call.timeout"' "$TMP/out/e.body" &&
    python3 -c "import sys; sys.exit(0 if 1.8 <= float('${out#* }') < 4 else 1)"; then
    pass e "GET /nothing gives 504 call.timeout after ${out#* } s"
  else
    fail e "GET /nothing gave $out $(cat "$TMP/out/e.body")"
  fi
}

check_f() {
  local status
  head -c 8192 /dev/zero | tr '\0' a >"$TMP/out/f.req"
  status=$(http f -X POST "$GW/sessions/x/messages" --data-binary @"$TMP/out/f.req")
  if [ "$status" = 413 ] && grep -q '"http.body_too_large"' "$TMP/out/f.body"; then
    pass f "an 8 KiB body gives 413"
  else
    fail f "an 8 KiB body gave $status"
  fi
}

check_g() {
  local session
  session=$(open_session gina)
  stream g "/sessions/$session/events?user=gina"
  stream_open g
  message gina "$session" "fail" >/dev/null
  until_ok 10 "[ \$(events g dead_lettered) -ge 1 ]"
  message gina "$session" "back again" >/dev/null
  until_ok 10 "awk '/^event: dead_lettered/{d=NR} /^event: output/{if (d && NR>d) f=1} END{exit !f}' $TMP/out/g.events"
  local found=$?
  local notice
  notice=$(grep -A1 '^event: dead_lettered' "$TMP/out/g.events" | tail -1)
  if [ $found = 0 ] && echo "$notice" | grep -q '"input.dead_lettered"' && ! echo "$notice" | grep -q 'sk-123\|"entry"'; then
    pass g "a dead_lettered event without the author's text or an entry, then the next turn's output"
  else
    fail g "found $found; notice: $notice"
  fi
}

check_h() {
  local session before after
  session=$(open_session hugo)
  stream h "/sessions/$session/events?user=hugo"
  stream_open h
  before=$(listeners "$session")
  kill "$(cat "$TMP/h.stream")"
  if [ "$before" -ge 1 ] && until_ok 3 "[ \$(listeners $session) -eq 0 ]"; then
    pass h "the killed client's listener left $session within 3 s"
  else
    fail h "listeners before $before, after $(listeners "$session")"
  fi
}

check_i() {
  local session status
  http i-open -X POST "$GW/sessions?user=ivy" >/dev/null
  session=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["session"])' "$TMP/out/i-open.body")
  stream i "/sessions/$session/events?user=ivy"
  if stream_open i 5; then
    pass i "a stream opened right after POST /sessions attached"
  else
    fail i "the stream did not attach: $(head -c 300 "$TMP/out/i.events")"
  fi
}

check_j() {
  local one two
  one=$(curl -s -o "$TMP/out/j1.body" -w '%{http_code} %{time_total}' "$GW/raw/ghost/events")
  until_ok 30 "flz operator start echo --id ghost-2 --namespace other || flz operator info ghost-2 --namespace other"
  two=$(curl -s -o "$TMP/out/j2.body" -w '%{http_code} %{time_total}' "$GW/raw/ghost-2/events")
  local ok=1
  for out in "$one" "$two"; do
    [ "${out% *}" = 404 ] && python3 -c "import sys; sys.exit(0 if 2.8 <= float('${out#* }') < 5 else 1)" || ok=0
  done
  if [ $ok = 1 ] && grep -q '"operator.not_found"' "$TMP/out/j2.body"; then
    pass j "ghost gives 404 after ${one#* } s, ghost-2 of namespace other after ${two#* } s"
  else
    fail j "ghost: $one, ghost-2: $two $(cat "$TMP/out/j2.body")"
  fi
}

check_k() {
  local session
  session=$(open_session kim)
  if ! until_ok 30 "operator_json $session | grep -q '\"phase\": \"suspended\"'"; then
    fail k "$session never reported asleep: $(flz operator info "$session" --json 2>&1 | head -c 300)"
    return
  fi
  stream k "/sessions/$session/events?user=kim"
  stream_open k
  message kim "$session" "wake up now" >/dev/null
  if until_ok 10 "[ \$(events k output) -ge 1 ]" && [ "$(payloads k part | tr '\n' ' ')" = "wake up now " ]; then
    pass k "an asleep session was streamed, and the message woke it and streamed"
  else
    fail k "events: $(tr '\n' ' ' <"$TMP/out/k.events" | head -c 300)"
  fi
}

check_l() {
  local status
  status=$(http l "http://127.0.0.1:18081/ping")
  if [ "$status" = 200 ] && [ "$(cat "$TMP/out/l.body")" = pong ]; then
    pass l "GET /ping on the steps pinger gives 200 pong"
  else
    fail l "GET /ping gave $status $(cat "$TMP/out/l.body")"
  fi
}

check_m() {
  local spec='[{"name":"web_pg2","provider":"http_server","hooks":["on_terminate"],"opts":{"port":"18090","channel":"http"}}]'
  start_operator pinger pg --partitions 2
  flz plugin enable web2 http_server --operator_id=pg --hook=on_terminate --Xport=18089 --Xchannel=http \
    >"$TMP/out/m.enable" 2>&1
  local refused=$? rows
  rows=$( (operator_json 'pg#p0'; operator_json 'pg#p1') | grep -c '"web2')
  flz operator start pinger --id pg2 --partitions 2 --plugins "$spec" --json >"$TMP/out/m.start" 2>&1
  local declined=$?
  if [ $refused != 0 ] && grep -q 'plugin.partitioned_host' "$TMP/out/m.enable" && [ "$rows" = 0 ] &&
    [ $declined != 0 ] && grep -q 'partitioned_host' "$TMP/out/m.start" && [ "$(operator_json 'pg2#p0')" = "{}" ]; then
    pass m "enable on a group is refused with plugin.partitioned_host and leaves no row; a group declaring it does not start"
  else
    fail m "enable exit $refused: $(cat "$TMP/out/m.enable"); rows $rows; start exit $declined: $(cat "$TMP/out/m.start")"
  fi
}

check_n() {
  flz plugin enable web3 http_server --operator_id=pinger --hook=on_terminate --Xport=18080 --Xchannel=http \
    >"$TMP/out/n.enable" 2>&1
  local refused=$?
  flz plugin disable web3 >/dev/null 2>&1
  if [ $refused != 0 ] && grep -q 'http.listen_failed' "$TMP/out/n.enable" &&
    [ "$(http n "$GW/no-route" -m 1)" = 404 ]; then
    pass n "a second server on 18080 fails with http.listen_failed, and the first keeps answering"
  else
    fail n "enable exit $refused: $(cat "$TMP/out/n.enable")"
  fi
}

check_o() {
  flz operator info gateway >"$TMP/out/o.info" 2>&1
  if grep -q '127.0.0.1:18080' "$TMP/out/o.info" && grep -q 'waiting' "$TMP/out/o.info" &&
    grep -q 'streams' "$TMP/out/o.info" && grep -q 'refused' "$TMP/out/o.info"; then
    pass o "flz operator info gateway shows the address and the counters"
  else
    fail o "$(cat "$TMP/out/o.info")"
  fi
}

check_p() {
  local session
  session=$(open_session pia)
  stream p "/sessions/$session/events?user=pia"
  stream_open p
  flz operator stop "$session" >"$TMP/out/p.stop" 2>&1
  if until_ok 30 "[ \$(events p ended) -ge 1 ]"; then
    pass p "stopping a streamed session gives an ended event"
  else
    fail p "no ended event: $(tr '\n' ' ' <"$TMP/out/p.events"); $(cat "$TMP/out/p.stop")"
  fi
}

check_r() {
  local killed
  killed=$(cd "$FLEZHA_CTL_DIR" && flzvm rpc '
    {:ok, pid} = Flezha.Service.OperatorManager.get_operator_pid("default", "gateway")
    Process.exit(pid, :kill)
    IO.puts(inspect(pid))' 2>&1)
  if until_ok 30 "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $GW/no-route -m 1)\" = 404 ]"; then
    pass r "after killing the gateway's Overwatch ($killed) a request on 18080 is answered again"
  else
    fail r "no answer on 18080 after the kill: $killed"
  fi
}

check_s() {
  start_operator echo echo
  stream s "/raw/echo/events"
  stream_open s
  flz operator send echo --text hi >/dev/null 2>&1
  if until_ok 10 "[ \$(events s output) -ge 1 ]" && [ "$(payloads s output)" = hi ]; then
    pass s "a flow operator's output reaches the stream"
  else
    fail s "events: $(tr '\n' ' ' <"$TMP/out/s.events")"
  fi
}

check_q() {
  flz plugin disable web >"$TMP/out/q.disable" 2>&1
  if until_ok 5 "! (echo >/dev/tcp/127.0.0.1/18080)"; then
    pass q "disabling the plugin refuses the next connection to 18080"
  else
    fail q "18080 still accepts: $(cat "$TMP/out/q.disable")"
  fi
}

# 20 sequential stream opens, from the request to the response headers.
timing() {
  start_operator echo timed
  for _ in $(seq 20); do
    curl -s -o /dev/null -m 0.5 -w '%{time_starttransfer}\n' "$GW/raw/timed/events"
  done | python3 -c '
import sys
t = [float(x) * 1000 for x in sys.stdin if float(x) > 0]
print(f"TIMING stream open: n={len(t)} mean={sum(t)/len(t):.1f} ms max={max(t):.1f} ms")'
}

# Sourced (by run_docker.sh), it only defines the checks.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

CHECKS=${*:-a b c d e f g h i j k l m n o p r s q}
controller_env "$TMP" "flzhttp$$" "$REL"
trap stop_all EXIT
setup
for check in $CHECKS; do
  # The timing needs the gateway's server, which the last check disables.
  [ "$check" = q ] && [ "${FLEZHA_E2E_TIMING:-0}" = 1 ] && timing
  "check_$check"
done
exit $FAILED
