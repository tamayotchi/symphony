defmodule SymphonyElixir.Manifest.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{
            port: non_neg_integer() | nil,
            host: String.t()
          }

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{
            dashboard_enabled: boolean(),
            refresh_ms: pos_integer(),
            render_interval_ms: pos_integer()
          }

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Project do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{
            id: String.t() | nil,
            workflow: String.t() | nil
          }

    @primary_key false
    embedded_schema do
      field(:id, :string)
      field(:workflow, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:id, :workflow], empty_values: [])
    end
  end

  embedded_schema do
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_many(:projects, Project, on_replace: :delete)
  end

  @spec parse(map()) :: {:ok, t()} | {:error, {:invalid_project_manifest, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} -> {:ok, settings}
      {:error, changeset} -> {:error, {:invalid_project_manifest, format_errors(changeset)}}
    end
  end

  @spec default_server() :: Server.t()
  def default_server, do: %Server{}

  @spec default_observability() :: Observability.t()
  def default_observability, do: %Observability{}

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:server, with: &Server.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:projects, with: &Project.changeset/2)
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      Map.put(acc, to_string(key), normalize_keys(nested))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp format_errors(changeset) do
    changeset.errors
    |> Enum.map_join(", ", fn {field, {message, _details}} -> "#{field} #{message}" end)
  end
end
