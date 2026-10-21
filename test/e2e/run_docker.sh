#!/usr/bin/env bash
# The plugin in the controller's Docker image:
#
#   test/e2e/run_docker.sh
#
# It builds the runtime image and the `plugin-builder` target from the core
# checkout, packages the plugin inside the builder (a copy of the core and the
# clone side by side, without build products), checks the package was built
# on the image's OTP, runs the controller container with the package installed
# (`flz plugin install`, then `docker restart`), its socket directory
# bind-mounted as docs/guides/runner_deployment.md shows and 18080 published on
# the host's loopback, and runs the chat fixture's runner on the host. The
# gateway listens on 0.0.0.0 inside the container, and checks (a) and (b) of
# run.sh pass from the host; enabled again with the default bind, the published
# port answers nothing. Every container, volume and image it created is removed.
set -uo pipefail

# shellcheck source=run.sh
source "$(dirname "$0")/run.sh"
RUN_ID=flzhttp$$
RUNTIME=flezha/flezha:$RUN_ID
BUILDER=flezha/plugin-builder:$RUN_ID
CONTROLLER=${RUN_ID}_controller

stop_all() {
  stop_streams
  stop_runner runner
  docker rm -f "$CONTROLLER" >/dev/null 2>&1
  docker rmi -f "$RUNTIME" "$BUILDER" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap stop_all EXIT

ctl() { docker exec "$CONTROLLER" /flezha/bin/flz "$@"; }

say "building the runtime image and the plugin-builder target"
docker build -q -f "$CORE/docker/prod/Dockerfile.controller" -t "$RUNTIME" "$CORE" >"$TMP/out/build.log" 2>&1 ||
  { tail -30 "$TMP/out/build.log"; exit 1; }
docker build -q --target plugin-builder -f "$CORE/docker/prod/Dockerfile.controller" -t "$BUILDER" "$CORE" \
  >>"$TMP/out/build.log" 2>&1 || { tail -30 "$TMP/out/build.log"; exit 1; }

# The core with this package at its submodule path, as the builder sees them,
# without the host's build products: the core's SDK test app fetches into a
# directory of its own, so the checkouts themselves are never mounted writable.
say "packaging the plugin inside the builder"
INNER="flezha/plugins/$(basename "$PLUGIN")"
mkdir -p "$TMP/pkg" "$TMP/s" "$TMP/code/flezha" "$TMP/code/$INNER"
(cd "$CORE" && tar -cf - --exclude='_build' --exclude='deps' --exclude='target' \
  mix.exs mix.lock config lib protobufs rel crates/flz_transport/errors.json crates/flz_core/src/schema.rs \
  crates/flz_core_ffi/src/veneer/shape.rs openspec/specs/java-sdk/spec.md test/fixtures sdk/elixir) |
  tar -xf - -C "$TMP/code/flezha"
(cd "$PLUGIN" && tar -cf - --exclude='_build' --exclude='deps' --exclude='test/e2e' .) |
  tar -xf - -C "$TMP/code/$INNER"
docker run --rm -v "$TMP/code:/code" -v "$TMP/pkg:/out" -w "/code/$INNER" \
  -e MIX_ENV=prod -e RUSTLER_SKIP_COMPILATION=true "$BUILDER" \
  sh -c "mix deps.get >/dev/null && mix flezha.plugin.package --output /out && chown -R $(id -u):$(id -g) /out /code" \
  >"$TMP/out/package.log" 2>&1 || { tail -30 "$TMP/out/package.log"; exit 1; }

package_otp=$(tar -xzOf "$TMP/pkg/flezha_http-0.1.0.fpz" manifest.exs | sed -n 's/.*otp: "\([0-9]*\)".*/\1/p')
runtime_otp=$(docker run --rm --entrypoint /flezha/bin/flzvm "$RUNTIME" eval 'IO.puts(System.otp_release())' | tail -1)
if [ -n "$package_otp" ] && [ "$package_otp" = "$runtime_otp" ]; then
  pass otp "the package was built on OTP $package_otp, the image runs OTP $runtime_otp"
else
  fail otp "the package was built on OTP '$package_otp', the image runs OTP '$runtime_otp'"
fi

say "the controller container, the package installed"
docker run -d --name "$CONTROLLER" -e FLEZHA_DURABILITY_BACKEND=none -e FLEZHA_AUTHZ_ENABLED=false \
  -v "$TMP/s:/flezha/storage/app/sockets" -v "$TMP/pkg:/pkgs:ro" -p 127.0.0.1:18080:18080 "$RUNTIME" >/dev/null
ctl boot await --timeout 120 >/dev/null || { docker logs "$CONTROLLER" | tail -30; exit 1; }
ctl plugin install /pkgs/flezha_http-0.1.0.fpz >"$TMP/out/install.log" 2>&1 || { cat "$TMP/out/install.log"; exit 1; }
docker restart "$CONTROLLER" >/dev/null
ctl boot await --timeout 120 >/dev/null || { docker logs "$CONTROLLER" | tail -30; exit 1; }
ctl plugin list --installed | grep -q 'flezha_http 0.1.0  loaded' || fail install "the package is not loaded"

say "the runner on the host, the gateway on 0.0.0.0"
build_runner
FLEZHA_SOCKET_FILES_PATH=$TMP/s start_runner runner default
web='[{"name":"web","provider":"http_server","hooks":["on_terminate"],"opts":{"port":"18080","bind":"0.0.0.0","channel":"http","pass_headers":"x-api-key"}}]'
until_ok 60 "ctl relay start gateway --id gateway --plugins '$web'" || { say "gateway did not start"; exit 1; }
until_ok 30 "curl -s -o /dev/null $GW/no-route" || { say "the published port does not answer"; exit 1; }
check_a
check_b

say "the default bind inside the container"
ctl plugin disable web >/dev/null
ctl plugin enable web2 http_server --relay_id=gateway --hook=on_terminate --Xport=18080 --Xchannel=http \
  >"$TMP/out/loopback.log" 2>&1
status=$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$GW/no-route")
if grep -q 'enabled successfully' "$TMP/out/loopback.log" && [ "$status" = 000 ]; then
  pass loopback "with the default bind the published port answers nothing"
else
  fail loopback "enable: $(cat "$TMP/out/loopback.log"); the published port answered $status"
fi

exit $FAILED
