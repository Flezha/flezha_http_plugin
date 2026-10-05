# flezha_http

The HTTP plugins for Flezha: a plugin package, `flezha_http`, with two providers on Bandit
and Plug.

- `http_server` puts a relay behind an HTTP/1.1 port. Every request becomes one outside
  call of the relay, the relay's `response()` answer becomes the HTTP response, and a
  stream answer turns the connection into server-sent events of another relay's parts
  and outputs. Its contract is the core's page `docs/plugins/http_server.md`.
- `http_api` serves the controller's published operations to a bearer token's principal,
  as MCP tools at `POST /mcp` and as plain JSON under `/v1`. It is a controller plugin,
  enabled in `_system`. Its contract is the core's page `docs/plugins/http_api.md`.

This README covers the repository.

## Layout

```
lib/flezha_http/provider.ex   the http_server provider: options, validation, its worker
lib/flezha_http/api_provider.ex  the http_api provider: options, the TLS rule, its worker
lib/flezha_http/server.ex     the worker of both: owns Bandit and the caps' counters
lib/flezha_http/handler.ex    the Plug: body, request envelope, the call, the answer
lib/flezha_http/envelope.ex   the request envelope and the answer decoding
lib/flezha_http/events.ex     a stream: the listener and the server-sent events
lib/flezha_http/status.ex     the HTTP status of every error code
lib/flezha_http/api.ex        the http_api Plug: origin, bearer token, routes, the door;
                              MCP itself is the core's Flezha.Mcp, shared with `flz mcp`
test/flezha_http/             unit tests (Plug.Test), server tests on a real Bandit,
                              the catalogue and docs-table checks
test/e2e/                     the chat fixture (an Elixir SDK runner) and run.sh
```

## Building and testing

The project depends on the Flezha core as a path dependency: it is the core's submodule at
`plugins/flezha_http_plugin`, so the core is `../..`. Nothing is published before go-live.

```
mix deps.get
RUSTLER_SKIP_COMPILATION=true mix compile --warnings-as-errors
RUSTLER_SKIP_COMPILATION=true mix test
RUSTLER_SKIP_COMPILATION=true mix format --check-formatted
```

`RUSTLER_SKIP_COMPILATION=true` keeps the core's native library out of the build: a plugin
never loads it. `mix test` runs with `--no-start`, so no controller boots; the tests start
Bandit alone and stand in for the relay. The catalogue test fails when a code the plugin
uses is missing from the core's `flz_transport/errors.json`, and the docs test when the
option table of `docs/plugins/http_server.md` or `docs/plugins/http_api.md` differs from
its provider's declaration, printing the table to put there.

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
docker build --target plugin-builder -t flezha/plugin-builder ../..
docker run --rm -v /path/to/flezha:/src -w /src/plugins/flezha_http_plugin flezha/plugin-builder \
  sh -c 'MIX_ENV=prod mix deps.get && MIX_ENV=prod RUSTLER_SKIP_COMPILATION=true mix flezha.plugin.package'
```

## Installing into a local release

```
flz plugin install _build/flezha_http-0.1.0.fpz
flz controller stop && flz controller start
flz plugin list --installed
```

Then enable `http_server` on a relay as `docs/plugins/http_server.md` shows.

## The end-to-end run

`test/e2e/run.sh` packages the plugin, installs it into a controller release under a
temporary plugin root, starts the controller and the chat fixture's runners, and checks the
plugin against a real release: requests, streams, bounds, errors, both relay kinds, a
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
