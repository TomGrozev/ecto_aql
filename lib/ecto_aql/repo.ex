defmodule EctoAQL.Repo do
  @doc false

  defmacro __using__(opts) do
    quote bind_quoted: [
            opts: opts
          ] do
      @otp_app opts[:otp_app]

      def child_spec(opts \\ []) do
        opts
        |> config()
        |> Arangox.child_spec()
      end

      def config(opts \\ []) do
        Application.get_env(@otp_app, __MODULE__, [])
        |> Keyword.merge(opts)
        |> Keyword.merge(otp_app: @otp_app, name: __MODULE__)
      end

      def all(struct, _opts \\ []) do
        {:ok, result} =
          query(
            """
            FOR doc IN #{collection(struct)}
              RETURN doc
            """
          )

        # Validates against the changeset
        result
        |> Enum.map(fn s ->
               struct
               |> validate_struct(s)
               |> document_changes()
             end)
      end

      def get(struct, id, _opts \\ []) do
        case Arangox.get(__MODULE__, "/_api/document/#{collection(struct)}/#{key_from_id(id)}") do
          {:ok, _, %{body: body}} ->
            {:ok, struct |> validate_struct(body) |> document_changes()}
          {:error, %{status: status}} -> {:error, status}
        end
      end

      def insert(struct, _opts \\ []) do
        document = document_changes(struct)

        case Arangox.post(
               __MODULE__,
               "/_api/document/#{collection(struct)}?returnNew=true",
               document
             ) do
          {:ok, _, %{body: body}} ->
            {:ok, struct |> validate_struct(body["new"]) |> document_changes()}
          {:error, %{status: status}} ->
            {:error, status}
        end
      end

      def insert!(struct, _opts \\ []) do
        document = document_changes(struct)

        {:ok, _, %{body: body}} =
          Arangox.post(
            __MODULE__,
            "/_api/document/#{collection(struct)}?returnNew=true",
            document
          )

        struct
        |> validate_struct(body["new"])
        |> document_changes()
      end

      def update(struct, id, _opts \\ []) do
        document = document_changes(struct)

        case Arangox.patch(
               __MODULE__,
               "/_api/document/#{collection(struct)}/#{id}?returnNew=true",
               document
             ) do
          {:ok, _, %{body: body}} ->
            {:ok, struct |> validate_struct(body["new"]) |> document_changes()}
          {:error, %{status: status}} ->
            {:error, status}
        end
      end

      def update!(struct, id, _opts \\ []) do
        document = document_changes(struct)

        {:ok, _, %{body: body}} =
          Arangox.patch(
            __MODULE__,
            "/_api/document/#{collection(struct)}/#{id}?returnNew=true",
            document
          )

        struct
        |> validate_struct(body["new"])
        |> document_changes()
      end

      def delete(struct, id, _opts \\ []) do
        case Arangox.delete(__MODULE__, "/_api/document/#{collection(struct)}/#{id}") do
          {:ok, _, _} -> :ok
          {:error, %{status: status}} -> {:error, status}
        end
      end

      def query(query_string) do
        Arangox.transaction(
          __MODULE__,
          fn cursor ->
            stream = Arangox.cursor(cursor, query_string)

            Enum.reduce(
              stream,
              [],
              fn resp, acc ->
                acc ++ resp.body["result"]
              end
            )
          end
        )
      end

      def list_collections do
        case Arangox.get(__MODULE__, "/_api/collection?excludeSystem=true") do
          {:ok, _, %{body: body}} -> {:ok, body["result"]}
          {:error, %{status: status}} -> {:error, status}
        end
      end

      def create_collection(name, type) do
        case Arangox.post(
               __MODULE__,
               "/_api/collection",
               %{
                 name: name,
                 type: collection_type(type)
               }
             ) do
          {:ok, _, _} -> :ok
          {:error, %{status: status}} -> {:error, status}
        end
      end

      def drop_collection(name) do
        case Arangox.delete(__MODULE__, "/_api/collection/#{name}") do
          {:ok, _, _} -> :ok
          {:error, %{status: status}} -> {:error, status}
        end
      end

      def list_databases do
        {:ok, conn} = system_db()

        case Arangox.get(conn, "/_api/database") do
          {:ok, _, %{body: body}} -> {:ok, body["result"]}
          {:error, %{status: status}} -> {:error, status}
        end
      end

      def create_database(name) do
        {:ok, conn} = system_db()

        case Arangox.post(conn, "/_api/database", %{name: name}) do
          {:ok, _, _} -> :ok
          {:error, %{status: status}} -> {:error, status}
        end
      end

      def drop_database(name) do
        {:ok, conn} = system_db()

        case Arangox.delete(conn, "/_api/database/#{name}") do
          {:ok, _, _} -> :ok
          {:error, %{status: status}} -> {:error, status}
        end
      end

      defp document_changes(struct) do
        struct
        |> Map.from_struct()
        |> Map.get(:changes)
      end

      defp validate_struct(queryable, %{} = params) do
        mod = module(queryable)
        mod.changeset(struct(mod.__struct__), params)
      end

      defp key_from_id(str) do
        IO.puts String.match?(str, ~r/[a-zA-Z0-9_]+\/[a-zA-Z0-9_]+/)
        if String.match?(str, ~r/[a-zA-Z0-9_]+\/[a-zA-Z0-9_]+/) do
          [_, key | _] = String.split(str, "/", [parts: 2])
          key
        else
          str
        end
      end

      defp module(%mod{} = struct), do: mod
      defp module(struct), do: struct

      defp collection(%Ecto.Changeset{} = struct), do: struct.data.__meta__.source
      defp collection(struct), do: struct.__struct__.__meta__.source

      defp collection_type(:document), do: 2
      defp collection_type(:edge), do: 3

      defp system_db do
        options = config(
          [
            pool_size: 1,
            database: "_system"
          ]
        )

        Arangox.start_link(options)
      end
    end
  end
end
