# flezha_http

The HTTP server plugin for Flezha: a plugin package, `flezha_http`, whose one provider,
`http_server`, puts an operator behind an HTTP/1.1 port. Every request becomes one outside
call of the operator, the operator's `response()` answer becomes the HTTP response, and a
stream answer turns the connection into server-sent events of another operator's parts and
outputs. It is built on Bandit and Plug.

The contract (options, envelopes, statuses, events, security, deployment) is the core's
page `docs/plugins/http_server.md`; this README covers the repository.

## Layout

```
lib/flezha_http/provider.ex   the provider: options, validation, the worker it declares
lib/flezha_http/server.ex     the worker: owns Bandit and the caps' counters
lib/flezha_http/handler.ex    the Plug: body, request envelope, the call, the answer
lib/flezha_http/envelope.ex   the request envelope and the answer decoding
lib/flezha_http/events.ex     a stream: the listener and the server-sent events
lib/flezha_http/status.ex     the HTTP status of every error code
test/flezha_http/             unit tests (Plug.Test), server tests on a real Bandit,
                              the catalogue and docs-table checks
test/e2e/                     the chat fixture (an Elixir SDK runner) and run.sh
```

## Building and testing

The project depends on the Flezha core as a path dependency, so the core checkout must sit
beside this one, at `../flezha`. Nothing is published before go-live.

```
mix deps.get
RUSTLER_SKIP_COMPILATION=true mix compile --warnings-as-errors
RUSTLER_SKIP_COMPILATION=true mix test
RUSTLER_SKIP_COMPILATION=true mix format --check-formatted
```

`RUSTLER_SKIP_COMPILATION=true` keeps the core's native library out of the build: a plugin
never loads it. `mix test` runs with `--no-start`, so no controller boots; the tests start
Bandit alone and stand in for the operator. The catalogue test fails when a code the plugin
uses is missing from the core's `flz_transport/errors.json`, and the docs test when the
option table of `docs/plugins/http_server.md` differs from the provider's declaration,
printing the table to put there.

## Packaging

On the host, with the same OTP and Elixir as the controller release:

```
MIX_ENV=prod mix deps.get
MIX_ENV=prod RUSTLER_SKIP_COMPILATION=true mix flezha.plugin.package
```

The archive is `_build/flezha_http-0.1.0.fpz`. It bundles Bandit, Plug, ThousandIsland,
WebSock, `mime` and `plug_crypto`, and nothing the release ships. For a controller image,
package it in the image's `plugin-builder` stage, so its OTP is the image's:

```
docker build --target plugin-builder -t flezha/plugin-builder ../flezha
docker run --rm -v /path/to/Code:/src -w /src/flezha_http_plugin flezha/plugin-builder \
  sh -c 'MIX_ENV=prod mix deps.get && MIX_ENV=prod RUSTLER_SKIP_COMPILATION=true mix flezha.plugin.package'
```

## Installing into a local release

```
flz plugin install _build/flezha_http-0.1.0.fpz
flz controller stop && flz controller start
flz plugin list --installed
```

Then enable `http_server` on an operator as `docs/plugins/http_server.md` shows.

## The end-to-end run

`test/e2e/run.sh` packages the plugin, installs it into a controller release under a
temporary plugin root, starts the controller and the chat fixture's runners, and checks the
plugin against a real release: requests, streams, bounds, errors, both operator kinds, a
restarted Overwatch and a disabled plugin. It prints PASS or FAIL per check, cleans up
everything it started, and exits non-zero on any failure.

```
test/e2e/run.sh              # every check
test/e2e/run.sh b g h        # some of them
FLEZHA_RELEASE=/path/to/rel test/e2e/run.sh
```

It uses ports 18080 and 18081. `FLEZHA_RELEASE` defaults to the core's
`_build/prod/rel/flezha`; `FLEZHA_E2E_TIMING=1` adds the stream-open timing.
`test/e2e/run_cluster.sh` moves the plugin between two controllers of one cluster.

## Continuous integration

None before go-live: the repository carries no workflow, as for the SDK repositories. Run
the commands above before committing.

## Licence

Apache-2.0, see `LICENSE`.
