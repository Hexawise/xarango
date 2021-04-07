defmodule Xarango.Domain.Graph do

  alias Xarango.Database
  alias Xarango.Graph
  alias Xarango.Vertex
  alias Xarango.Edge
  alias Xarango.VertexCollection
  alias Xarango.EdgeDefinition
  alias Xarango.EdgeCollection
  alias Xarango.SimpleQuery
  alias Xarango.Traversal
  alias Xarango.Util
  alias Xarango.AQL

  defmacro __using__(options\\[]) do
    db = options[:db] && Atom.to_string(options[:db]) || Xarango.Server.server.database
    gr = options[:graph] && Xarango.Util.name_from(options[:graph])
    quote do
      require Xarango.Domain.Graph
      import Xarango.Domain.Graph
      defstruct graph: %Xarango.Graph{}
      Module.register_attribute __MODULE__, :relationships, accumulate: true
      def _database, do: %Database{name: unquote(db)}
      def _graph, do: %Graph{name: unquote(gr) || Xarango.Util.name_from(__MODULE__) }
      def create, do: ensure()
      def ensure do
        Database.ensure(_database())
        Graph.ensure(_graph(), _database())
        Enum.each(_relationships(), &ensure_collections(&1, _graph(), _database()))
        struct(__MODULE__, graph: Graph.graph(_graph(), _database()))
      end
      def destroy, do: Graph.destroy(_graph(), _database())
      def add(from, relationship, to, data\\nil), do: add(from, relationship, to, data, _graph(), _database())
      def ensure(from, relationship, to, data\\nil), do: ensure(from, relationship, to, data, _graph(), _database())
      def remove(from, relationship, to), do: remove(from, relationship, to, _graph(), _database())
      def get(from, relationship, to), do: get(from, relationship, to, _graph(), _database())
      def traverse(start, options\\[]), do: traverse(start, options, _graph(), _database())
      def ensure_relationships(start_node, end_nodes), do: ensure_relationships(start_node, end_nodes, _relationships(), _graph(), _database())
      @before_compile Xarango.Domain.Graph
    end
  end

  defmacro relationship(from, relationship, to) do
    {relationship, from, to} = {Atom.to_string(relationship), Macro.expand(from, __CALLER__), Macro.expand(to, __CALLER__)}
    quote do
      relationship = %{from: unquote(from), to: unquote(to), name: unquote(relationship)}
      unless Enum.member?(@relationships, relationship), do: @relationships relationship
    end
  end

  defmacro __before_compile__(env) do
    relationships = Module.get_attribute(env.module, :relationships)
    methods = Enum.map relationships, fn %{from: from, to: to, name: relationship} ->
      add_method = "add_#{relationship}" |> String.to_atom
      ensure_method = "ensure_#{relationship}" |> String.to_atom
      remove_method = "remove_#{relationship}" |> String.to_atom
      inbound_method = "#{relationship}_#{Util.short_name_from(to)}" |> String.to_atom
      outbound_method = "#{Util.short_name_from(from)}_#{relationship}" |> String.to_atom
      quote do
        def unquote(add_method)(%unquote(from){} = from, %unquote(to){} = to), do: unquote(add_method)(from, to, nil)
        def unquote(add_method)(%unquote(from){} = from, %unquote(to){} = to, data), do:  add(from, unquote(relationship), to, data)
        def unquote(ensure_method)(%unquote(from){} = from, %unquote(to){} = to), do: unquote(ensure_method)(from, to, nil)
        def unquote(ensure_method)(%unquote(from){} = from, %unquote(to){} = to, data), do: ensure(from, unquote(relationship), to, data)
        def unquote(remove_method)(%unquote(from){} = from, %unquote(to){} = to), do: remove(from, unquote(relationship), to)
        def unquote(inbound_method)(%unquote(from){} = from), do: get(from, unquote(relationship), unquote(to))
        def unquote(outbound_method)(%unquote(to){} = to), do: get(unquote(from), unquote(relationship), to)
      end
    end
    quote do
      def _relationships, do: @relationships
      unquote(methods)
    end
  end

  def add(from_node, relationship, to_node, data, graph, database) when is_atom(relationship) do
    add(from_node, Atom.to_string(relationship), to_node, data, graph, database)
  end
  def add(from_node, relationship, to_node, data, graph, database) when is_binary(relationship) do
    from_vertex = Vertex.ensure(from_node.vertex, apply(from_node.__struct__, :_collection, []), graph, database)
    to_vertex = Vertex.ensure(to_node.vertex, apply(to_node.__struct__, :_collection, []), graph, database)
    edge = %Edge{_from: from_vertex._id, _to: to_vertex._id, _data: data}
    edge_collection = %EdgeCollection{collection: relationship }
    Edge.create(edge, edge_collection, graph, database)
  end

  def ensure(from, relationship, to, data, graph, database) do
    case get(from, relationship, to, graph, database) do
      [] -> add(from, relationship, to, data, graph, database)
      [edge] -> edge
    end
  end

  def remove(from_node, relationship, to_node, graph, database) when is_atom(relationship) do
    remove(from_node, Atom.to_string(relationship), to_node, graph, database)
  end
  def remove(from_node, relationship, to_node, graph, database) when is_binary(relationship) do
    example = %{_from: from_node.vertex._id, _to: to_node.vertex._id}
    edge_collection = %EdgeCollection{collection: relationship }
    %SimpleQuery{example: example, collection: edge_collection.collection}
    |> SimpleQuery.by_example(database)
    |> Enum.map(&Edge.destroy(&1, edge_collection, graph, database))
  end

  def get(from, relationship, to, graph, database) when is_atom(relationship) do
    get(from, Atom.to_string(relationship), to, graph, database)
  end
  def get(%{} = from_node, relationship, %{} = to_node, graph, database) when is_binary(relationship) do
    AQL.outbound(from_node, relationship, to_node) |> edge_query(graph, database)
  end
  def get(from, relationship, %{} = to_node, graph, database) when is_binary(relationship) do
    AQL.inbound(to_node, relationship) |> vertex_query(from, graph, database)
  end
  def get(%{} = from_node, relationship, to, graph, database) when is_binary(relationship) do
    AQL.outbound(from_node, relationship) |> vertex_query(to, graph, database)
  end

  defp vertex_query(aql, node, _graph, database) do
    aql
    |> AQL.options([bfs: true, uniqueVertices: "global"])
    |> Xarango.Query.query(database)
    |> Xarango.QueryResult.to_vertex
    |> node.to_node
  end
  defp edge_query(aql, _graph, database) do
    aql
    |> Xarango.Query.query(database)
    |> Xarango.QueryResult.to_edge
  end


  def traverse(start, options, graph, database) do
    traversal = options
      |> Enum.into(%{})
      |> Map.merge(%{direction: "outbound"}, fn _k, v1, _v2 -> v1 end)
      |> Map.merge(%{startVertex: start.vertex._id})
      |> Map.merge(%{graphName: graph.name})
      |> Map.merge(%{uniqueness: %{vertices: "global", edges: "global"}})
    struct(Traversal, traversal)
    |> Traversal.traverse(database)
  end

  def ensure_collections(rel, graph, database) do
    {collection, from, to} = {rel[:name], rel[:from]._collection, rel[:to]._collection}
    from_indexes = rel[:from].indexes
    to_indexes = rel[:to].indexes
    from |> VertexCollection.ensure(graph, database, from_indexes)
    to |> VertexCollection.ensure(graph, database, to_indexes)
    %EdgeDefinition{collection: collection , from: [from.collection], to: [to.collection]} |> EdgeDefinition.ensure(graph, database)
  end

  def ensure_relationships(%{} = start_node, end_nodes, relationships, graph, database) do
    stringified_end_nodes = Util.stringify_keys(end_nodes)
    relationships
    |> Enum.each(fn %{name: name} = relationship ->
      case stringified_end_nodes[name] do
        nil -> :noop
        end_nodes -> ensure_directed(start_node, relationship, end_nodes, nil, graph, database)
      end
    end)
    end_nodes
  end

  defp ensure_directed(start_node, relationship, end_nodes, data, graph, database) when is_list(end_nodes) do
    end_nodes |> Enum.each(&ensure_directed(start_node, relationship, &1, data, graph, database))
  end
  defp ensure_directed(start_node, %{from: from, name: name, to: to}, end_node, data, graph, database) do
    case {start_node.__struct__, end_node.__struct__} do
      {^from, ^to} -> ensure(start_node, name, end_node, data, graph, database)
      {^to, ^from} -> ensure(end_node, name, start_node, data, graph, database)
      _ -> :noop
    end
  end

end
