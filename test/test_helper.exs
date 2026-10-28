# The suite runs with `--no-start`: no controller boots, and only the server
# library the tests drive is started. The handler's per-request debug line is
# asserted where it matters and kept out of the rest.
{:ok, _} = Application.ensure_all_started(:bandit)
# The ports `FlezhaHttp.Client.free_port/0` handed out, held for the run.
:ets.new(FlezhaHttp.Client, [:named_table, :public, :set])
Logger.configure(level: :info)
ExUnit.start()
