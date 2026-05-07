defmodule SymphonyElixir.RuntimeContext do
  @moduledoc false

  @context_key {__MODULE__, :context}

  @type t :: %{
          optional(:project_id) => String.t(),
          optional(:workflow_path) => Path.t()
        }

  @spec get() :: t()
  def get do
    Process.get(@context_key, %{})
  end

  @spec put(map()) :: :ok
  def put(context) when is_map(context) do
    Process.put(@context_key, Map.merge(get(), context))
    :ok
  end

  @spec clear() :: :ok
  def clear do
    Process.delete(@context_key)
    :ok
  end

  @spec workflow_path() :: Path.t() | nil
  def workflow_path do
    get()[:workflow_path]
  end

  @spec project_id() :: String.t() | nil
  def project_id do
    get()[:project_id]
  end

  @spec with_context(map(), (() -> result)) :: result when result: var
  def with_context(context, fun) when is_map(context) and is_function(fun, 0) do
    previous = get()

    try do
      put(context)
      fun.()
    after
      if previous == %{} do
        clear()
      else
        Process.put(@context_key, previous)
      end
    end
  end
end
