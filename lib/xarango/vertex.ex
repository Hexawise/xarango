defmodule Xarango.Vertex do

  defstruct [:_id, :_key, :_rev, :_oldRev, :_data]

  alias Xarango.Vertex
  import Xarango.Client
  use Xarango.URI, prefix: "gharial"

  def vertex(%Vertex{_id: id}, database\\nil) when is_binary(id) do
    Xarango.Document.url(id, database)
    |> get
    |> to_vertex
  end

  def vertex(vertex, collection, graph, database\\nil) do
    url = case vertex do
      %{_id: id} when id != nil -> id
      %{_key: key} when key != nil -> "#{collection}/#{key}"
      _ -> raise Xarango.Error, message: "Vertex not specified"
    end
    url("#{graph.name}/vertex/#{url}", database)
    |> get
    |> to_vertex
  end

  def edges(vertex, edge_collection, options\\[], database\\nil) do
    options = Keyword.merge(options, [vertex: vertex._id])
    Xarango.Client._url(Xarango.URI.path("edges/#{edge_collection.collection}", database), options)
    |> get
    |> Map.get(:edges)
    |> Enum.map(&Xarango.Edge.to_edge(&1))
  end

  def create(vertex, collection, graph, database\\nil) do
    url("#{graph.name}/vertex/#{collection.collection}", database)
    |> post(vertex._data)
    |> to_vertex
  end

  def update(vertex, collection, graph, database\\nil) do
    url("#{graph.name}/vertex/#{collection.collection}/#{vertex._key}", database)
    |> patch(vertex._data)
    |> to_vertex
  end

  def replace(vertex, collection, graph, database\\nil) do
    url("#{graph.name}/vertex/#{collection.collection}/#{vertex._key}", database)
    |> put(vertex._data)
    |> to_vertex
  end

  def destroy(vertex, collection, graph, database\\nil) do
    url("#{graph.name}/vertex/#{collection.collection}/#{vertex._key}", database)
    |> delete
  end

  def ensure(vertex, collection, graph, database\\nil) do
    try do
      vertex(vertex, collection, graph, database)
    rescue
      Xarango.Error -> create(vertex, collection, graph, database)
    end
  end

  def to_vertex(vertices) when is_list(vertices) do
    Enum.map(vertices, &to_vertex(&1))
  end

  def to_vertex(data) do
    data = Map.get(data, :vertex, data)
    struct(Vertex, decode_data(data, Vertex))
  end

end

defmodule Xarango.VertexCollection do

  defstruct [:collection]

  def vertices(collection, database\\nil) do
    Xarango.Document.documents(%{name: collection.collection}, database)
    |> Enum.map(&to_vertex(&1))
  end

  def ensure(collection, graph, database\\nil, indexes\\[]) do
    collections = Xarango.Graph.vertex_collections(graph, database) |> Enum.map(&(&1.collection)) |> MapSet.new
    case MapSet.member?(collections, collection.collection) do
      false ->
        Xarango.Graph.add_vertex_collection(graph, collection, database)
        Enum.each(indexes, &Xarango.Index.create(&1, collection.collection, database))
        collection
      true -> collection
    end
  end

  defp to_vertex(document) do
    doc = Map.from_struct(document)
    struct(Xarango.Vertex, doc)
  end

end
