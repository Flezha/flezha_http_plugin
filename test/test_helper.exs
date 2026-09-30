# The suite runs with `--no-start`: no controller boots, and only the server
# library the tests drive is started. The handler's per-request debug line is
# asserted where it matters and kept out of the rest.
{:ok, _} = Application.ensure_all_started(:bandit)
Logger.configure(level: :info)
ExUnit.start()
