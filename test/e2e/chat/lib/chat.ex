defmodule Chat do
  @moduledoc """
  The chat fixture the end-to-end run drives through the HTTP server plugin.

    * `gateway` (unbounded, keyed by user): the plugin's host. It routes each
      request envelope, keeps each user's session register and daily token
      budget, answers every request through `response()`, and calls the `agent`
      factory to open a session or to hand it a message.
    * `agent` (bounded, `per_input`, `keep_progress`, durable, sleeping when
      idle): one per session. A turn sends one part per word 100 ms apart,
      emits the answer on the sink `events`, and answers the gateway's call with
      the tokens it used; the message `fail` fails the turn for good.
    * `pinger` (bounded, `per_input`): answers every request `pong`.
    * `echo` (unbounded): emits every input on the sink `out`.
  """

  @budget 40

  @doc "The request envelope as the gateway reads it."
  def decode(bytes) do
    with {:ok, %{"method" => method, "path" => path, "query" => query} = envelope} <-
           Jason.decode(bytes) do
      {:ok,
       %{
         method: method,
         route: String.split(path, "/", trim: true),
         user: URI.decode_query(query)["user"] || "anonymous",
         key: get_in(envelope, ["headers", "x-api-key"]),
         body: envelope["body"] || ""
       }}
    end
  end

  @doc "The user a call's outcome belongs to: the one its request names."
  def user_of(%Flezha.SDK.Response{request: request}), do: Jason.decode!(request)["user"]

  def answer?(item), do: Map.has_key?(item, "answer")
  def open?(item), do: Map.has_key?(item, "open")
  def turn?(item), do: Map.has_key?(item, "turn")

  @doc "What the gateway does with one request of `user`, given the user's account."
  def route(%{method: "POST", route: ["sessions"], user: user}, account) do
    session = "#{user}-#{account["next"]}"

    account = %{
      account
      | "next" => account["next"] + 1,
        "sessions" => [session | account["sessions"]]
    }

    {[
       answer(201, %{session: session}),
       %{"open" => %{"session" => session, "user" => user, "text" => ""}}
     ], account}
  end

  def route(%{method: "POST", route: ["sessions", session, "messages"]} = request, account) do
    cond do
      request.key != "test-key" ->
        {[answer(401, "an x-api-key is required")], account}

      account["tokens"] >= @budget ->
        {[answer(429, "daily budget spent", %{"retry-after" => "3600"})], account}

      session not in account["sessions"] ->
        {[answer(404, "no such session")], account}

      true ->
        text = Jason.decode!(request.body)["text"]

        {[
           answer(202, %{accepted: true}),
           %{"turn" => %{"session" => session, "user" => request.user, "text" => text}}
         ], account}
    end
  end

  def route(%{method: "GET", route: ["sessions", session, "events"]}, account) do
    if session in account["sessions"],
      do: {[%{"answer" => %{"stream" => session}}], account},
      else: {[answer(404, "no such session")], account}
  end

  def route(%{method: "GET", route: ["raw", target, "events"]}, account),
    do: {[%{"answer" => %{"stream" => target}}], account}

  def route(%{method: "GET", route: ["nothing"]}, account), do: {[], account}
  def route(_request, account), do: {[answer(404, "no such route")], account}

  defp answer(status, body, headers \\ %{}),
    do: %{"answer" => %{"status" => status, "headers" => headers, "body" => body}}

  @doc "A day's account: the sessions, the next session number and the tokens used today."
  def account(nil), do: fresh()

  def account(%{"day" => day} = account),
    do:
      if(day == today(),
        do: account,
        else: %{fresh() | "sessions" => account["sessions"], "next" => account["next"]}
      )

  defp fresh, do: %{"day" => today(), "tokens" => 0, "sessions" => [], "next" => 1}
  defp today, do: Date.to_iso8601(Date.utc_today())

  defmodule Account do
    @moduledoc false
    use Flezha.SDK.Tasklet, name: "account"

    @impl true
    def run(%Flezha.SDK.Response{result: {:ok, %{"tokens" => tokens}}}, state, _ctx) do
      account = Chat.account(state)
      {:ok, %{account | "tokens" => account["tokens"] + tokens}}
    end

    def run(%Flezha.SDK.Response{}, state, _ctx), do: {:ok, state}

    def run(request, state, ctx) do
      {items, account} = Chat.route(request, Chat.account(state))
      Enum.each(items, &emit(ctx, &1))
      {:ok, account}
    end
  end

  defmodule Answer do
    @moduledoc false
    use Flezha.SDK.Tasklet, name: "answer"

    @impl true
    def run(%{"answer" => answer}, state, ctx) do
      emit(ctx, answer)
      {:ok, state}
    end
  end

  defmodule Open do
    @moduledoc false
    use Flezha.SDK.Tasklet, name: "open"

    @impl true
    def run(%{"open" => open}, state, ctx) do
      emit(ctx, open)
      {:ok, state}
    end
  end

  defmodule Turn do
    @moduledoc false
    use Flezha.SDK.Tasklet, name: "turn"

    @impl true
    def run(%{"turn" => turn}, state, ctx) do
      emit(ctx, turn)
      {:ok, state}
    end
  end

  defmodule Gateway do
    @moduledoc false
    use Flezha.SDK.UnboundedOperator, factory_id: "gateway"

    @call [deadline_ms: 120_000, decode: &Jason.decode/1]

    @impl true
    def channels(c) do
      account =
        c
        |> input_with("http", &Chat.decode/1)
        |> key_by(& &1.user)
        |> into(Chat.Account)
        |> named("account")

      account |> filter(&Chat.answer?/1) |> into(Chat.Answer) |> response()

      account
      |> filter(&Chat.open?/1)
      |> into(Chat.Open)
      |> named("open")
      |> key_by(& &1["session"])
      |> call([factory: "agent"] ++ @call)
      |> key_by(&Chat.user_of/1)
      |> into(Chat.Account)

      account
      |> filter(&Chat.turn?/1)
      |> into(Chat.Turn)
      |> named("turn")
      |> key_by(& &1["session"])
      |> call([factory: "agent", create: false] ++ @call)
      |> key_by(&Chat.user_of/1)
      |> into(Chat.Account)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Flezha.SDK.BoundedOperator,
      factory_id: "agent",
      loop_mode: :per_input,
      rollback_mode: :keep_progress,
      persistence_enabled: true,
      sleep_when_idle: true,
      self_terminating?: false,
      max_duration_ms: 86_400_000

    @impl true
    def channels(c) do
      c
      |> input("turn")
      |> into(Chat.Agent.Turn)
      |> sink("events")
      |> into(Chat.Agent.Usage)
      |> response()
    end

    defmodule Turn do
      @moduledoc false
      use Flezha.SDK.Tasklet, name: "agent_turn"

      @impl true
      def run(bytes, state, ctx) do
        case Jason.decode!(bytes)["text"] do
          "fail" ->
            {:error, {:non_retryable, "upstream key sk-123 rejected"}}

          text ->
            words = String.split(text)

            for word <- words do
              :ok = Flezha.SDK.Ctx.part(ctx, word)
              Process.sleep(100)
            end

            emit(ctx, %{"text" => text, "tokens" => length(words)})
            {:ok, state}
        end
      end
    end

    defmodule Usage do
      @moduledoc false
      use Flezha.SDK.Tasklet, name: "agent_usage"

      @impl true
      def run(%{"tokens" => tokens}, state, ctx) do
        emit(ctx, %{"tokens" => tokens})
        {:ok, state}
      end
    end
  end

  defmodule Pinger do
    @moduledoc false
    use Flezha.SDK.BoundedOperator, factory_id: "pinger", loop_mode: :per_input

    # Keyed on its entry, so the end-to-end run can start it as a partition group.
    @impl true
    def channels(c) do
      c
      |> input("http")
      |> key_by(&Jason.decode!(&1)["path"])
      |> into(Chat.Pinger.Pong)
      |> response()
    end

    defmodule Pong do
      @moduledoc false
      use Flezha.SDK.Tasklet, name: "pong"

      @impl true
      def run(_request, state, ctx) do
        emit(ctx, %{"status" => 200, "body" => "pong"})
        {:ok, state}
      end
    end
  end

  defmodule Echo do
    @moduledoc false
    use Flezha.SDK.UnboundedOperator, factory_id: "echo", input: "in", sink: "out"

    def run(input, state, ctx) do
      emit(ctx, input)
      {:ok, state}
    end
  end
end
