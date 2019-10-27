Code.require_file "../../../integration_test/support/types.exs", __DIR__

defmodule Ecto.Query.PlannerTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Ecto.Query.Planner
  alias Ecto.Query.JoinExpr

  defmodule Comment do
    use Ecto.Schema

    schema "comments" do
      field :text, :string
      field :temp, :string, virtual: true
      field :posted, :naive_datetime
      field :uuid, :binary_id
      field :crazy_comment, :string

      belongs_to :post, Ecto.Query.PlannerTest.Post

      belongs_to :crazy_post, Ecto.Query.PlannerTest.Post,
        where: [title: "crazypost"]

      belongs_to :crazy_post_with_list, Ecto.Query.PlannerTest.Post,
        where: [title: {:in, ["crazypost1", "crazypost2"]}],
        foreign_key: :crazy_post_id,
        define_field: false

      has_many :post_comments, through: [:post, :comments]
      has_many :comment_posts, Ecto.Query.PlannerTest.CommentPost
    end
  end

  defmodule CommentPost do
    use Ecto.Schema

    schema "comment_posts" do
      belongs_to :comment, Comment
      belongs_to :post, Post
      belongs_to :special_comment, Comment, where: [text: nil]
      belongs_to :special_long_comment, Comment, where: [text: {:fragment, "LEN(?) > 100"}]

      field :deleted, :boolean
    end

    def inactive() do
      dynamic([row], row.deleted)
    end
  end

  defmodule Post do
    use Ecto.Schema

    @primary_key {:id, CustomPermalink, []}
    @schema_prefix "my_prefix"
    schema "posts" do
      field :title, :string, source: :post_title
      field :text, :string
      field :code, :binary
      field :posted, :naive_datetime
      field :visits, :integer
      field :links, {:array, CustomPermalink}
      field :payload, :map, load_in_query: false

      has_many :comments, Ecto.Query.PlannerTest.Comment
      has_many :extra_comments, Ecto.Query.PlannerTest.Comment
      has_many :special_comments, Ecto.Query.PlannerTest.Comment, where: [text: {:not, nil}]
      many_to_many :crazy_comments, Comment, join_through: CommentPost, where: [text: "crazycomment"]
      many_to_many :crazy_comments_with_list, Comment, join_through: CommentPost, where: [text: {:in, ["crazycomment1", "crazycomment2"]}]
      many_to_many :crazy_comments_without_schema, Comment, join_through: "comment_posts"
    end
  end

  defp plan(query, operation \\ :all) do
    Planner.plan(query, operation, Ecto.TestAdapter)
  end

  defp normalize(query, operation \\ :all) do
    normalize_with_params(query, operation) |> elem(0)
  end

  defp normalize_with_params(query, operation \\ :all) do
    {query, params, _key} = plan(query, operation)

    {query, select} =
      query
      |> Planner.ensure_select(operation == :all)
      |> Planner.normalize(operation, Ecto.TestAdapter, 0)

    {query, params, select}
  end

  defp select_fields(fields, ix) do
    for field <- fields do
      {{:., [], [{:&, [], [ix]}, field]}, [], []}
    end
  end

  test "plan: merges all parameters" do
    union = from p in Post, select: {p.title, ^"union"}
    subquery = from Comment, where: [text: ^"subquery"]

    query =
      from p in Post,
        select: {p.title, ^"select"},
        join: c in subquery(subquery),
        on: c.text == ^"join",
        left_join: d in assoc(p, :comments),
        union_all: ^union,
        windows: [foo: [partition_by: fragment("?", ^"windows")]],
        where: p.title == ^"where",
        group_by: p.title == ^"group_by",
        having: p.title == ^"having",
        order_by: [asc: fragment("?", ^"order_by")],
        limit: ^0,
        offset: ^1

    {_query, params, _key} = plan(query)
    assert params ==
             ["select", "subquery", "join", "where", "group_by", "having", "windows"] ++
               ["union", "order_by", 0, 1]
  end

  test "plan: checks from" do
    assert_raise Ecto.QueryError, ~r"query must have a from expression", fn ->
      plan(%Ecto.Query{})
    end
  end

  test "plan: casts values" do
    {_query, params, _key} = plan(Post |> where([p], p.id == ^"1"))
    assert params == [1]

    exception = assert_raise Ecto.Query.CastError, fn ->
      plan(Post |> where([p], p.title == ^1))
    end

    assert Exception.message(exception) =~ "value `1` in `where` cannot be cast to type :string"
    assert Exception.message(exception) =~ "where: p0.title == ^1"
  end

  test "plan: raises readable error on dynamic expressions/keyword lists" do
    dynamic = dynamic([p], p.id == ^"1")
    {_query, params, _key} = plan(Post |> where([p], ^dynamic))
    assert params == [1]

    assert_raise Ecto.QueryError, ~r/dynamic expressions can only be interpolated/, fn ->
      plan(Post |> where([p], p.title == ^dynamic))
    end

    assert_raise Ecto.QueryError, ~r/keyword lists can only be interpolated/, fn ->
      plan(Post |> where([p], p.title == ^[foo: 1]))
    end
  end

  test "plan: casts and dumps custom types" do
    permalink = "1-hello-world"
    {_query, params, _key} = plan(Post |> where([p], p.id == ^permalink))
    assert params == [1]
  end

  test "plan: casts and dumps binary ids" do
    uuid = "00010203-0405-4607-8809-0a0b0c0d0e0f"
    {_query, params, _key} = plan(Comment |> where([c], c.uuid == ^uuid))
    assert params == [<<0, 1, 2, 3, 4, 5, 70, 7, 136, 9, 10, 11, 12, 13, 14, 15>>]

    assert_raise Ecto.Query.CastError,
                 ~r/`"00010203-0405-4607-8809"` cannot be dumped to type :binary_id/, fn ->
      uuid = "00010203-0405-4607-8809"
      plan(Comment |> where([c], c.uuid == ^uuid))
    end
  end

  test "plan: casts and dumps custom types in left side of in-expressions" do
    permalink = "1-hello-world"
    {_query, params, _key} = plan(Post |> where([p], ^permalink in p.links))
    assert params == [1]

    message = ~r"value `\"1-hello-world\"` in `where` expected to be part of an array but matched type is :string"
    assert_raise Ecto.Query.CastError, message, fn ->
      plan(Post |> where([p], ^permalink in p.text))
    end
  end

  test "plan: casts and dumps custom types in right side of in-expressions" do
    datetime = ~N[2015-01-07 21:18:13.0]
    {_query, params, _key} = plan(Comment |> where([c], c.posted in ^[datetime]))
    assert params == [~N[2015-01-07 21:18:13]]

    permalink = "1-hello-world"
    {_query, params, _key} = plan(Post |> where([p], p.id in ^[permalink]))
    assert params == [1]

    datetime = ~N[2015-01-07 21:18:13.0]
    {_query, params, _key} = plan(Comment |> where([c], c.posted in [^datetime]))
    assert params == [~N[2015-01-07 21:18:13]]

    permalink = "1-hello-world"
    {_query, params, _key} = plan(Post |> where([p], p.id in [^permalink]))
    assert params == [1]

    {_query, params, _key} = plan(Post |> where([p], p.code in [^"abcd"]))
    assert params == ["abcd"]

    {_query, params, _key} = plan(Post |> where([p], p.code in ^["abcd"]))
    assert params == ["abcd"]
  end

  test "plan: casts values on update_all" do
    {_query, params, _key} = plan(Post |> update([p], set: [id: ^"1"]), :update_all)
    assert params == [1]

    {_query, params, _key} = plan(Post |> update([p], set: [title: ^nil]), :update_all)
    assert params == [nil]

    {_query, params, _key} = plan(Post |> update([p], set: [title: nil]), :update_all)
    assert params == []
  end

  test "plan: joins" do
    query = from(p in Post, join: c in "comments") |> plan |> elem(0)
    assert hd(query.joins).source == {"comments", nil}

    query = from(p in Post, join: c in Comment) |> plan |> elem(0)
    assert hd(query.joins).source == {"comments", Comment}

    query = from(p in Post, join: c in {"post_comments", Comment}) |> plan |> elem(0)
    assert hd(query.joins).source == {"post_comments", Comment}
  end

  test "plan: joins associations" do
    query = from(p in Post, join: assoc(p, :comments)) |> plan |> elem(0)
    assert %JoinExpr{on: on, source: source, assoc: nil, qual: :inner} = hd(query.joins)
    assert source == {"comments", Comment}
    assert Macro.to_string(on.expr) == "&1.post_id() == &0.id()"

    query = from(p in Post, left_join: assoc(p, :comments)) |> plan |> elem(0)
    assert %JoinExpr{on: on, source: source, assoc: nil, qual: :left} = hd(query.joins)
    assert source == {"comments", Comment}
    assert Macro.to_string(on.expr) == "&1.post_id() == &0.id()"

    query = from(p in Post, left_join: c in assoc(p, :comments), on: p.title == c.text) |> plan |> elem(0)
    assert %JoinExpr{on: on, source: source, assoc: nil, qual: :left} = hd(query.joins)
    assert source == {"comments", Comment}
    assert Macro.to_string(on.expr) == "&1.post_id() == &0.id() and &0.title() == &1.text()"
  end

  test "plan: nested joins associations" do
    query = from(c in Comment, left_join: assoc(c, :post_comments)) |> plan |> elem(0)
    assert {{"comments", _, _}, {"comments", _, _}, {"posts", _, _}} = query.sources
    assert [join1, join2] = query.joins
    assert Enum.map(query.joins, & &1.ix) == [2, 1]
    assert Macro.to_string(join1.on.expr) == "&2.id() == &0.post_id()"
    assert Macro.to_string(join2.on.expr) == "&1.post_id() == &2.id()"

    query = from(p in Comment, left_join: assoc(p, :post),
                               left_join: assoc(p, :post_comments)) |> plan |> elem(0)
    assert {{"comments", _, _}, {"posts", _, _}, {"comments", _, _}, {"posts", _, _}} = query.sources
    assert [join1, join2, join3] = query.joins
    assert Enum.map(query.joins, & &1.ix) == [1, 3, 2]
    assert Macro.to_string(join1.on.expr) == "&1.id() == &0.post_id()"
    assert Macro.to_string(join2.on.expr) == "&3.id() == &0.post_id()"
    assert Macro.to_string(join3.on.expr) == "&2.post_id() == &3.id()"

    query = from(p in Comment, left_join: assoc(p, :post_comments),
                               left_join: assoc(p, :post)) |> plan |> elem(0)
    assert {{"comments", _, _}, {"comments", _, _}, {"posts", _, _}, {"posts", _, _}} = query.sources
    assert [join1, join2, join3] = query.joins
    assert Enum.map(query.joins, & &1.ix) == [3, 1, 2]
    assert Macro.to_string(join1.on.expr) == "&3.id() == &0.post_id()"
    assert Macro.to_string(join2.on.expr) == "&1.post_id() == &3.id()"
    assert Macro.to_string(join3.on.expr) == "&2.id() == &0.post_id()"
  end

  test "plan: joins associations with custom queries" do
    query = from(p in Post, left_join: assoc(p, :special_comments)) |> plan |> elem(0)

    assert {{"posts", _, _}, {"comments", _, _}} = query.sources
    assert [join] = query.joins
    assert join.ix == 1
    assert Macro.to_string(join.on.expr) =~
             ~r"&1.post_id\(\) == &0.id\(\) and not[\s\(]is_nil\(&1.text\(\)\)\)?"
  end

  test "plan: nested joins associations with custom queries" do
    query = from(p in Post,
                   join: c1 in assoc(p, :special_comments),
                   join: p2 in assoc(c1, :post),
                   join: cp in assoc(c1, :comment_posts),
                   join: c2 in assoc(cp, :special_comment),
                   join: c3 in assoc(cp, :special_long_comment))
                   |> plan
                   |> elem(0)

    assert [join1, join2, join3, join4, join5] = query.joins
    assert {{"posts", _, _}, {"comments", _, _}, {"posts", _, _},
            {"comment_posts", _, _}, {"comments", _, _}, {"comments", _, _}} = query.sources

    assert Macro.to_string(join1.on.expr) =~
           ~r"&1.post_id\(\) == &0.id\(\) and not[\s\(]is_nil\(&1.text\(\)\)\)?"
    assert Macro.to_string(join2.on.expr) == "&2.id() == &1.post_id()"
    assert Macro.to_string(join3.on.expr) == "&3.comment_id() == &1.id()"
    assert Macro.to_string(join4.on.expr) == "&4.id() == &3.special_comment_id() and is_nil(&4.text())"
    assert Macro.to_string(join5.on.expr) ==
           "&5.id() == &3.special_long_comment_id() and fragment({:raw, \"LEN(\"}, {:expr, &5.text()}, {:raw, \") > 100\"})"
  end

  test "plan: cannot associate without schema" do
    query   = from(p in "posts", join: assoc(p, :comments))
    message = ~r"cannot perform association join on \"posts\" because it does not have a schema"

    assert_raise Ecto.QueryError, message, fn ->
      plan(query)
    end
  end

  test "plan: requires an association field" do
    query = from(p in Post, join: assoc(p, :title))

    assert_raise Ecto.QueryError, ~r"could not find association `title`", fn ->
      plan(query)
    end
  end

  test "plan: handles specific param type-casting" do
    value = NaiveDateTime.utc_now
    {_, params, _} = from(p in Post, where: p.posted > datetime_add(^value, 1, "second")) |> plan()
    assert params == [value]

    value = DateTime.utc_now
    {_, params, _} = from(p in Post, where: p.posted > datetime_add(^value, 1, "second")) |> plan()
    assert params == [value]

    value = ~N[2010-04-17 14:00:00]
    {_, params, _} =
      from(p in Post, where: p.posted > datetime_add(^"2010-04-17 14:00:00", 1, "second")) |> plan()
    assert params == [value]
  end

  test "plan: generates a cache key" do
    {_query, _params, key} = plan(from(Post, []))
    assert key == [:all, {"posts", Post, 36606244, "my_prefix"}]

    query =
      from(
        p in Post,
        prefix: "hello",
        select: 1,
        lock: "foo",
        where: is_nil(nil),
        or_where: is_nil(nil),
        join: c in Comment,
        prefix: "world",
        preload: :comments
      )

    {_query, _params, key} = plan(%{query | prefix: "foo"})
    assert key == [:all,
                   {:lock, "foo"},
                   {:prefix, "foo"},
                   {:where, [{:and, {:is_nil, [], [nil]}}, {:or, {:is_nil, [], [nil]}}]},
                   {:join, [{:inner, {"comments", Comment, 38292156, "world"}, true}]},
                   {"posts", Post, 36606244, "hello"},
                   {:select, 1}]
  end

  test "plan: generates a cache key for in based on the adapter" do
    query = from(p in Post, where: p.id in ^[1, 2, 3])
    {_query, _params, key} = Planner.plan(query, :all, Ecto.TestAdapter)
    assert key == :nocache
  end

  test "plan: combination with uncacheable queries are uncacheable" do
    query1 =
      Post
      |> where([p], p.id in ^[1, 2, 3])
      |> select([p], p.id)

    query2 =
      Post
      |> where([p], p.id in [1, 2])
      |> select([p], p.id)
      |> distinct(true)

    {_, _, key} = query1 |> union_all(^query2) |> Planner.plan(:all, Ecto.TestAdapter)
    assert key == :nocache
  end

  test "plan: ctes with uncacheable queries are uncacheable" do
    {_, _, cache} =
      Comment
      |> with_cte("cte", as: ^from(c in Comment, where: c.id in ^[1, 2, 3]))
      |> plan()

    assert cache == :nocache
  end

  test "plan: normalizes prefixes" do
    # No schema prefix in from
    {query, _, _} = from(Comment, select: 1) |> plan()
    assert query.sources == {{"comments", Comment, nil}}

    {query, _, _} = from(Comment, select: 1) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"comments", Comment, "global"}}

    {query, _, _} = from(Comment, prefix: "local", select: 1) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"comments", Comment, "local"}}

    # Schema prefix in from
    {query, _, _} = from(Post, select: 1) |> plan()
    assert query.sources == {{"posts", Post, "my_prefix"}}

    {query, _, _} = from(Post, select: 1) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"posts", Post, "my_prefix"}}

    {query, _, _} = from(Post, prefix: "local", select: 1) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"posts", Post, "local"}}

    # No schema prefix in join
    {query, _, _} = from(c in Comment, join: assoc(c, :comment_posts)) |> plan()
    assert query.sources == {{"comments", Comment, nil}, {"comment_posts", CommentPost, nil}}

    {query, _, _} = from(c in Comment, join: assoc(c, :comment_posts)) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"comments", Comment, "global"}, {"comment_posts", CommentPost, "global"}}

    {query, _, _} = from(c in Comment, join: assoc(c, :comment_posts), prefix: "local") |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"comments", Comment, "global"}, {"comment_posts", CommentPost, "local"}}

    # Schema prefix in join
    {query, _, _} = from(c in Comment, join: assoc(c, :post)) |> plan()
    assert query.sources == {{"comments", Comment, nil}, {"posts", Post, "my_prefix"}}

    {query, _, _} = from(c in Comment, join: assoc(c, :post)) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"comments", Comment, "global"}, {"posts", Post, "my_prefix"}}

    {query, _, _} = from(c in Comment, join: assoc(c, :post), prefix: "local") |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"comments", Comment, "global"}, {"posts", Post, "local"}}

    # Schema prefix for many-to-many joins
    {query, _, _} = from(c in Post, join: assoc(c, :crazy_comments)) |> plan()
    assert query.sources == {{"posts", Post, "my_prefix"}, {"comments", Comment, nil}, {"comment_posts", CommentPost, nil}}

    {query, _, _} = from(c in Post, join: assoc(c, :crazy_comments)) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"posts", Post, "my_prefix"}, {"comments", Comment, "global"}, {"comment_posts", CommentPost, "global"}}

    {query, _, _} = from(c in Post, join: assoc(c, :crazy_comments), prefix: "local") |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"posts", Post, "my_prefix"}, {"comments", Comment, "local"}, {"comment_posts", CommentPost, "local"}}

    # Schema prefix for many-to-many joins (when join_through is a table name)
    {query, _, _} = from(c in Post, join: assoc(c, :crazy_comments_without_schema)) |> plan()
    assert query.sources == {{"posts", Post, "my_prefix"}, {"comments", Comment, nil}, {"comment_posts", nil, nil}}

    {query, _, _} = from(c in Post, join: assoc(c, :crazy_comments_without_schema)) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"posts", Post, "my_prefix"}, {"comments", Comment, "global"}, {"comment_posts", nil, "global"}}

    {query, _, _} = from(c in Post, join: assoc(c, :crazy_comments_without_schema), prefix: "local") |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"posts", Post, "my_prefix"}, {"comments", Comment, "local"}, {"comment_posts", nil, "local"}}

    # Schema prefix for has through
    {query, _, _} = from(c in Comment, join: assoc(c, :post_comments)) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"comments", Comment, "global"}, {"comments", Comment, "global"}, {"posts", Ecto.Query.PlannerTest.Post, "my_prefix"}}

    {query, _, _} = from(c in Comment, join: assoc(c, :post_comments), prefix: "local") |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"comments", Comment, "global"}, {"comments", Comment, "local"}, {"posts", Ecto.Query.PlannerTest.Post, "local"}}
  end

  test "plan: combination queries" do
    {%{combinations: [{_, query}]}, _, cache} = from(c in Comment, union: ^from(c in Comment)) |> plan()
    assert query.sources == {{"comments", Comment, nil}}
    assert %Ecto.Query.SelectExpr{expr: {:&, [], [0]}} = query.select
    assert [:all, {:union, _}, _] = cache

    {%{combinations: [{_, query}]}, _, cache} = from(c in Comment, union: ^from(c in Comment, where: c in ^[1, 2, 3])) |> plan()
    assert query.sources == {{"comments", Comment, nil}}
    assert %Ecto.Query.SelectExpr{expr: {:&, [], [0]}} = query.select
    assert :nocache = cache
  end

  test "plan: normalizes prefixes for combinations" do
    # No schema prefix in from
    assert {%{combinations: [{_, union_query}]} = query, _, _} = from(Comment,  union: ^from(Comment)) |> plan()
    assert query.sources == {{"comments", Comment, nil}}
    assert union_query.sources == {{"comments", Comment, nil}}

    assert {%{combinations: [{_, union_query}]} = query, _, _} = from(Comment, union: ^from(Comment)) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"comments", Comment, "global"}}
    assert union_query.sources == {{"comments", Comment, "global"}}

    assert {%{combinations: [{_, union_query}]} = query, _, _} = from(Comment, prefix: "local", union: ^from(Comment)) |> plan()
    assert query.sources == {{"comments", Comment, "local"}}
    assert union_query.sources == {{"comments", Comment, nil}}

    assert {%{combinations: [{_, union_query}]} = query, _, _} = from(Comment, prefix: "local", union: ^from(Comment)) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"comments", Comment, "local"}}
    assert union_query.sources == {{"comments", Comment, "global"}}

    assert {%{combinations: [{_, union_query}]} = query, _, _} = from(Comment, prefix: "local", union: ^(from(Comment) |> Map.put(:prefix, "union"))) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"comments", Comment, "local"}}
    assert union_query.sources == {{"comments", Comment, "union"}}

    # With schema prefix
    assert {%{combinations: [{_, union_query}]} = query, _, _} = from(Post, union: ^from(p in Post)) |> plan()
    assert query.sources == {{"posts", Post, "my_prefix"}}
    assert union_query.sources == {{"posts", Post, "my_prefix"}}

    assert {%{combinations: [{_, union_query}]} = query, _, _} = from(Post, union: ^from(Post)) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"posts", Post, "my_prefix"}}
    assert union_query.sources == {{"posts", Post, "my_prefix"}}

    assert {%{combinations: [{_, union_query}]} = query, _, _} = from(Post, prefix: "local", union: ^from(Post)) |> plan()
    assert query.sources == {{"posts", Post, "local"}}
    assert union_query.sources == {{"posts", Post, "my_prefix"}}

    assert {%{combinations: [{_, union_query}]} = query, _, _} = from(Post, prefix: "local", union: ^from(Post)) |> Map.put(:prefix, "global") |> plan()
    assert query.sources == {{"posts", Post, "local"}}
    assert union_query.sources == {{"posts", Post, "my_prefix"}}

    # Deep-nested unions
    assert {%{combinations: [{_, upper_level_union_query}]} = query, _, _} = from(Comment, union: ^from(Comment, union: ^from(Comment))) |> plan()
    assert %{combinations: [{_, deeper_level_union_query}]} = upper_level_union_query
    assert query.sources == {{"comments", Comment, nil}}
    assert upper_level_union_query.sources == {{"comments", Comment, nil}}
    assert deeper_level_union_query.sources == {{"comments", Comment, nil}}

    assert {%{combinations: [{_, upper_level_union_query}]} = query, _, _} = from(Comment, union: ^from(Comment, union: ^from(Comment))) |> Map.put(:prefix, "global") |> plan()
    assert %{combinations: [{_, deeper_level_union_query}]} = upper_level_union_query
    assert query.sources == {{"comments", Comment, "global"}}
    assert upper_level_union_query.sources == {{"comments", Comment, "global"}}
    assert deeper_level_union_query.sources == {{"comments", Comment, "global"}}

    assert {%{combinations: [{_, upper_level_union_query}]} = query, _, _} = from(Comment, prefix: "local", union: ^from(Comment, union: ^from(Comment))) |> plan()
    assert %{combinations: [{_, deeper_level_union_query}]} = upper_level_union_query
    assert query.sources == {{"comments", Comment, "local"}}
    assert upper_level_union_query.sources == {{"comments", Comment, nil}}
    assert deeper_level_union_query.sources == {{"comments", Comment, nil}}

    assert {%{combinations: [{_, upper_level_union_query}]} = query, _, _} = from(Comment, prefix: "local", union: ^from(Comment, union: ^from(Comment))) |> Map.put(:prefix, "global") |> plan()
    assert %{combinations: [{_, deeper_level_union_query}]} = upper_level_union_query
    assert query.sources == {{"comments", Comment, "local"}}
    assert upper_level_union_query.sources == {{"comments", Comment, "global"}}
    assert deeper_level_union_query.sources == {{"comments", Comment, "global"}}
  end

  test "plan: CTEs on all" do
    {%{with_ctes: with_expr}, _, cache} =
      Comment
      |> with_cte("cte", as: ^from(c in Comment))
      |> plan()
    %{queries: [{"cte", query}]} = with_expr
    assert query.sources == {{"comments", Comment, nil}}
    assert %Ecto.Query.SelectExpr{expr: {:&, [], [0]}} = query.select
    assert [
      :all,
      {"comments", Comment, _, nil},
      {:non_recursive_cte, "cte", [{"comments", Comment, _, nil}, {:select, {:&, _, [0]}}]}
    ] = cache

    {%{with_ctes: with_expr}, _, cache} =
      Comment
      |> with_cte("cte", as: ^from(c in Comment, where: c in ^[1, 2, 3]))
      |> plan()
    %{queries: [{"cte", query}]} = with_expr
    assert query.sources == {{"comments", Comment, nil}}
    assert %Ecto.Query.SelectExpr{expr: {:&, [], [0]}} = query.select
    assert :nocache = cache

    {%{with_ctes: with_expr}, _, cache} =
      Comment
      |> recursive_ctes(true)
      |> with_cte("cte", as: fragment("SELECT * FROM comments WHERE id = ?", ^123))
      |> plan()
    %{queries: [{"cte", query_expr}]} = with_expr
    expr = {:fragment, [], [raw: "SELECT * FROM comments WHERE id = ", expr: {:^, [], [0]}, raw: ""]}
    assert expr == query_expr.expr
    assert [:all, {"comments", Comment, _, nil}, {:recursive_cte, "cte", ^expr}] = cache
  end

  test "plan: CTEs on update_all" do
    recent_comments =
      from(c in Comment,
        order_by: [desc: c.posted],
        limit: ^500,
        select: [:id]
      )

    {%{with_ctes: with_expr}, [500, "text"], cache} =
      Comment
      |> with_cte("recent_comments", as: ^recent_comments)
      |> join(:inner, [c], r in "recent_comments", on: c.id == r.id)
      |> update(set: [text: ^"text"])
      |> select([c, r], c)
      |> plan(:update_all)

    %{queries: [{"recent_comments", cte}]} = with_expr
    assert {{"comments", Comment, nil}} = cte.sources
    assert %{expr: {:^, [], [0]}, params: [{500, :integer}]} = cte.limit

    assert [:update_all, _, _, _, _, {:non_recursive_cte, "recent_comments", cte_cache}] = cache
    assert [
             {:limit, {:^, [], [0]}},
             {:order_by, [[desc: _]]},
             {"comments", Comment, _, nil},
             {:select, {:&, [], [0]}}
           ] = cte_cache
  end

  test "plan: CTEs on delete_all" do
    recent_comments =
      from(c in Comment,
        order_by: [desc: c.posted],
        limit: ^500,
        select: [:id]
      )

    {%{with_ctes: with_expr}, [500, "text"], cache} =
      Comment
      |> with_cte("recent_comments", as: ^recent_comments)
      |> join(:inner, [c], r in "recent_comments", on: c.id == r.id and c.text == ^"text")
      |> select([c, r], c)
      |> plan(:delete_all)

    %{queries: [{"recent_comments", cte}]} = with_expr
    assert {{"comments", Comment, nil}} = cte.sources
    assert %{expr: {:^, [], [0]}, params: [{500, :integer}]} = cte.limit

    assert [:delete_all, _, _, _, {:non_recursive_cte, "recent_comments", cte_cache}] = cache
    assert [
             {:limit, {:^, [], [0]}},
             {:order_by, [[desc: _]]},
             {"comments", Comment, _, nil},
             {:select, {:&, [], [0]}}
           ] = cte_cache
  end

  test "plan: CTE prefixes" do
    {%{with_ctes: with_expr} = query, _, _} = Comment |> with_cte("cte", as: ^from(c in Comment)) |> plan()
    %{queries: [{"cte", cte_query}]} = with_expr
    assert query.sources == {{"comments", Comment, nil}}
    assert cte_query.sources == {{"comments", Comment, nil}}

    {%{with_ctes: with_expr} = query, _, _} = Comment |> with_cte("cte", as: ^from(c in Comment)) |> Map.put(:prefix, "global") |> plan()
    %{queries: [{"cte", cte_query}]} = with_expr
    assert query.sources == {{"comments", Comment, "global"}}
    assert cte_query.sources == {{"comments", Comment, "global"}}

    {%{with_ctes: with_expr} = query, _, _} = Comment |> with_cte("cte", as: ^(from(c in Comment) |> Map.put(:prefix, "cte"))) |> Map.put(:prefix, "global") |> plan()
    %{queries: [{"cte", cte_query}]} = with_expr
    assert query.sources == {{"comments", Comment, "global"}}
    assert cte_query.sources == {{"comments", Comment, "cte"}}
  end

  test "normalize: validates literal types" do
    assert_raise Ecto.QueryError, fn ->
      Comment |> where([c], c.text == 123) |> normalize()
    end

    assert_raise Ecto.QueryError, fn ->
      Comment |> where([c], c.text == '123') |> normalize()
    end
  end

  test "normalize: tagged types" do
    {query, params, _select} = from(Post, []) |> select([p], type(^"1", :integer))
                                              |> normalize_with_params
    assert query.select.expr ==
           %Ecto.Query.Tagged{type: :integer, value: {:^, [], [0]}, tag: :integer}
    assert params == [1]

    {query, params, _select} = from(Post, []) |> select([p], type(^"1", CustomPermalink))
                                              |> normalize_with_params
    assert query.select.expr ==
           %Ecto.Query.Tagged{type: :id, value: {:^, [], [0]}, tag: CustomPermalink}
    assert params == [1]

    {query, params, _select} = from(Post, []) |> select([p], type(^"1", p.visits))
                                              |> normalize_with_params
    assert query.select.expr ==
           %Ecto.Query.Tagged{type: :integer, value: {:^, [], [0]}, tag: :integer}
    assert params == [1]

    assert_raise Ecto.Query.CastError, ~r/value `"1"` in `select` cannot be cast to type Ecto.UUID/, fn ->
      from(Post, []) |> select([p], type(^"1", Ecto.UUID)) |> normalize
    end
  end

  test "normalize: assoc join with wheres that have regular filters" do
    {_query, params, _select} =
      from(post in Post,
        join: comment in assoc(post, :crazy_comments),
        join: post in assoc(comment, :crazy_post)) |> normalize_with_params()

    assert params == ["crazycomment", "crazypost"]
  end

  test "normalize: assoc join with wheres that have in filters" do
    {_query, params, _select} =
      from(post in Post,
        join: comment in assoc(post, :crazy_comments_with_list),
        join: post in assoc(comment, :crazy_post_with_list)) |> normalize_with_params()

    assert params == ["crazycomment1", "crazycomment2", "crazypost1", "crazypost2"]

    {query, params, _} =
      Ecto.assoc(%Comment{crazy_post_id: 1}, :crazy_post_with_list)
      |> normalize_with_params()

    assert Macro.to_string(hd(query.wheres).expr) == "&0.id() == ^0 and &0.post_title() in ^(1, 2)"
    assert params == [1, "crazypost1", "crazypost2"]
  end

  test "normalize: dumps in query expressions" do
    assert_raise Ecto.QueryError, ~r"cannot be dumped", fn ->
      normalize(from p in Post, where: p.posted == "2014-04-17 00:00:00")
    end
  end

  test "normalize: validate fields" do
    message = ~r"field `unknown` in `select` does not exist in schema Ecto.Query.PlannerTest.Comment"
    assert_raise Ecto.QueryError, message, fn ->
      query = from(Comment, []) |> select([c], c.unknown)
      normalize(query)
    end

    message = ~r"field `temp` in `select` is a virtual field in schema Ecto.Query.PlannerTest.Comment"
    assert_raise Ecto.QueryError, message, fn ->
      query = from(Comment, []) |> select([c], c.temp)
      normalize(query)
    end
  end

  test "normalize: validate fields in left side of in expressions" do
    query = from(Post, []) |> where([p], p.id in [1, 2, 3])
    normalize(query)

    message = ~r"value `\[1, 2, 3\]` cannot be dumped to type \{:array, :string\}"
    assert_raise Ecto.QueryError, message, fn ->
      query = from(Comment, []) |> where([c], c.text in [1, 2, 3])
      normalize(query)
    end
  end

  test "normalize: flattens and expands right side of in expressions" do
    {query, params, _select} = where(Post, [p], p.id in [1, 2, 3]) |> normalize_with_params()
    assert Macro.to_string(hd(query.wheres).expr) == "&0.id() in [1, 2, 3]"
    assert params == []

    {query, params, _select} = where(Post, [p], p.id in [^1, 2, ^3]) |> normalize_with_params()
    assert Macro.to_string(hd(query.wheres).expr) == "&0.id() in [^0, 2, ^1]"
    assert params == [1, 3]

    {query, params, _select} = where(Post, [p], p.id in ^[]) |> normalize_with_params()
    assert Macro.to_string(hd(query.wheres).expr) == "&0.id() in ^(0, 0)"
    assert params == []

    {query, params, _select} = where(Post, [p], p.id in ^[1, 2, 3]) |> normalize_with_params()
    assert Macro.to_string(hd(query.wheres).expr) == "&0.id() in ^(0, 3)"
    assert params == [1, 2, 3]

    {query, params, _select} = where(Post, [p], p.title == ^"foo" and p.id in ^[1, 2, 3] and
                                                p.title == ^"bar") |> normalize_with_params()
    assert Macro.to_string(hd(query.wheres).expr) ==
           "&0.post_title() == ^0 and &0.id() in ^(1, 3) and &0.post_title() == ^4"
    assert params == ["foo", 1, 2, 3, "bar"]
  end

  test "normalize: reject empty order by and group by" do
    query = order_by(Post, [], []) |> normalize()
    assert query.order_bys == []

    query = order_by(Post, [], ^[]) |> normalize()
    assert query.order_bys == []

    query = group_by(Post, [], []) |> normalize()
    assert query.group_bys == []
  end

  test "normalize: select" do
    query = from(Post, []) |> normalize()
    assert query.select.expr ==
             {:&, [], [0]}
    assert query.select.fields ==
           select_fields([:id, :post_title, :text, :code, :posted, :visits, :links], 0)

    query = from(Post, []) |> select([p], {p, p.title, "Post"}) |> normalize()
    assert query.select.fields ==
           select_fields([:id, :post_title, :text, :code, :posted, :visits, :links], 0) ++
           [{{:., [type: :string], [{:&, [], [0]}, :post_title]}, [], []}]

    query = from(Post, []) |> select([p], {p.title, p, "Post"}) |> normalize()
    assert query.select.fields ==
           select_fields([:id, :post_title, :text, :code, :posted, :visits, :links], 0) ++
           [{{:., [type: :string], [{:&, [], [0]}, :post_title]}, [], []}]

    query =
      from(Post, [])
      |> join(:inner, [_], c in Comment)
      |> preload([_, c], comments: c)
      |> select([p, _], {p.title, p})
      |> normalize()
    assert query.select.fields ==
           select_fields([:id, :post_title, :text, :code, :posted, :visits, :links], 0) ++
           select_fields([:id, :text, :posted, :uuid, :crazy_comment, :post_id, :crazy_post_id], 1) ++
           [{{:., [type: :string], [{:&, [], [0]}, :post_title]}, [], []}]
  end

  test "normalize: select with unions" do
    union_query = from(Post, []) |> select([p], %{title: p.title, category: "Post"})
    query = from(Post, []) |> select([p], %{title: p.title, category: "Post"}) |> union(^union_query) |> normalize()

    union_query = query.combinations |> List.first() |> elem(1)
    assert "Post" in query.select.fields
    assert query.select.fields == union_query.select.fields
  end

  test "normalize: select on schemaless" do
    assert_raise Ecto.QueryError, ~r"need to explicitly pass a :select clause in query", fn ->
      from("posts", []) |> normalize()
    end
  end

  test "normalize: select with struct/2" do
    assert_raise Ecto.QueryError, ~r"struct/2 in select expects a source with a schema", fn ->
      "posts" |> select([p], struct(p, [:id, :title])) |> normalize()
    end

    query = Post |> select([p], struct(p, [:id, :title])) |> normalize()
    assert query.select.expr == {:&, [], [0]}
    assert query.select.fields == select_fields([:id, :post_title], 0)

    query = Post |> select([p], {struct(p, [:id, :title]), p.title}) |> normalize()
    assert query.select.fields ==
           select_fields([:id, :post_title], 0) ++
           [{{:., [type: :string], [{:&, [], [0]}, :post_title]}, [], []}]

    query =
      Post
      |> join(:inner, [_], c in Comment)
      |> select([p, c], {p, struct(c, [:id, :text])})
      |> normalize()
    assert query.select.fields ==
           select_fields([:id, :post_title, :text, :code, :posted, :visits, :links], 0) ++
           select_fields([:id, :text], 1)
  end

  test "normalize: select with struct/2 on assoc" do
    query =
      Post
      |> join(:inner, [_], c in Comment)
      |> select([p, c], struct(p, [:id, :title, comments: [:id, :text]]))
      |> preload([p, c], comments: c)
      |> normalize()
    assert query.select.expr == {:&, [], [0]}
    assert query.select.fields ==
           select_fields([:id, :post_title], 0) ++
           select_fields([:id, :text], 1)

    query =
      Post
      |> join(:inner, [_], c in Comment)
      |> select([p, c], struct(p, [:id, :title, comments: [:id, :text, post: :id], extra_comments: :id]))
      |> preload([p, c], comments: {c, post: p}, extra_comments: c)
      |> normalize()
    assert query.select.expr == {:&, [], [0]}
    assert query.select.fields ==
           select_fields([:id, :post_title], 0) ++
           select_fields([:id, :text], 1) ++
           select_fields([:id], 0) ++
           select_fields([:id], 1)
  end

  test "normalize: select with map/2" do
    query = Post |> select([p], map(p, [:id, :title])) |> normalize()
    assert query.select.expr == {:&, [], [0]}
    assert query.select.fields == select_fields([:id, :post_title], 0)

    query = Post |> select([p], {map(p, [:id, :title]), p.title}) |> normalize()
    assert query.select.fields ==
           select_fields([:id, :post_title], 0) ++
           [{{:., [type: :string], [{:&, [], [0]}, :post_title]}, [], []}]

    query =
      Post
      |> join(:inner, [_], c in Comment)
      |> select([p, c], {p, map(c, [:id, :text])})
      |> normalize()
    assert query.select.fields ==
           select_fields([:id, :post_title, :text, :code, :posted, :visits, :links], 0) ++
           select_fields([:id, :text], 1)
  end

  test "normalize: select with map/2 on assoc" do
    query =
      Post
      |> join(:inner, [_], c in Comment)
      |> select([p, c], map(p, [:id, :title, comments: [:id, :text]]))
      |> preload([p, c], comments: c)
      |> normalize()
    assert query.select.expr == {:&, [], [0]}
    assert query.select.fields ==
           select_fields([:id, :post_title], 0) ++
           select_fields([:id, :text], 1)

    query =
      Post
      |> join(:inner, [_], c in Comment)
      |> select([p, c], map(p, [:id, :title, comments: [:id, :text, post: :id], extra_comments: :id]))
      |> preload([p, c], comments: {c, post: p}, extra_comments: c)
      |> normalize()
    assert query.select.expr == {:&, [], [0]}
    assert query.select.fields ==
           select_fields([:id, :post_title], 0) ++
           select_fields([:id, :text], 1) ++
            select_fields([:id], 0) ++
           select_fields([:id], 1)
  end

  test "normalize: windows" do
    assert_raise Ecto.QueryError, ~r"unknown window :v given to over/2", fn ->
      Comment
      |> windows([c], w: [partition_by: c.id])
      |> select([c], count(c.id) |> over(:v))
      |> normalize()
    end
  end

  test "normalize: preload errors" do
    message = ~r"the binding used in `from` must be selected in `select` when using `preload`"
    assert_raise Ecto.QueryError, message, fn ->
      Post |> preload(:hello) |> select([p], p.title) |> normalize
    end

    message = ~r"invalid query has specified more bindings than"
    assert_raise Ecto.QueryError, message, fn ->
      Post |> preload([p, c], comments: c) |> normalize
    end
  end

  test "normalize: preload assoc merges"  do
    {_, _, select} =
      from(p in Post)
      |> join(:inner, [p], c in assoc(p, :comments))
      |> join(:inner, [_, c], cp in assoc(c, :comment_posts))
      |> join(:inner, [_, c], ip in assoc(c, :post))
      |> preload([_, c, cp, _], comments: {c, comment_posts: cp})
      |> preload([_, c, _, ip], comments: {c, post: ip})
      |> normalize_with_params()

    assert select.assocs == [comments: {1, [comment_posts: {2, []}, post: {3, []}]}]
  end

  test "normalize: preload assoc errors" do
    message = ~r"field `Ecto.Query.PlannerTest.Post.not_field` in preload is not an association"
    assert_raise Ecto.QueryError, message, fn ->
      query = from(p in Post, join: c in assoc(p, :comments), preload: [not_field: c])
      normalize(query)
    end

    message = ~r"requires an inner, left or lateral join, got right join"
    assert_raise Ecto.QueryError, message, fn ->
      query = from(p in Post, right_join: c in assoc(p, :comments), preload: [comments: c])
      normalize(query)
    end
  end

  test "normalize: fragments do not support preloads" do
    query = from p in Post, join: c in fragment("..."), preload: [comments: c]
    assert_raise Ecto.QueryError, ~r/can only preload sources with a schema/, fn ->
      normalize(query)
    end
  end

  test "normalize: all does not allow updates" do
    message = ~r"`all` does not allow `update` expressions"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, update: [set: [name: "foo"]]) |> normalize(:all)
    end
  end

  test "normalize: all does not allow bindings in order bys when having combinations" do
    assert_raise Ecto.QueryError,  ~r"cannot use bindings in `order_by` when using `union_all`", fn ->
      posts_query = from(post in Post, select: post.id)
      posts_query
      |> union_all(^posts_query)
      |> order_by([post], post.id)
      |> normalize(:all)
    end
  end

  test "normalize: update all only allow filters and checks updates" do
    message = ~r"`update_all` requires at least one field to be updated"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, select: p, update: []) |> normalize(:update_all)
    end

    message = ~r"duplicate field `title` for `update_all`"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, select: p, update: [set: [title: "foo", title: "bar"]])
      |> normalize(:update_all)
    end

    message = ~r"`update_all` allows only `with_cte`, `where` and `join` expressions"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, order_by: p.title, update: [set: [title: "foo"]]) |> normalize(:update_all)
    end
  end

  test "normalize: delete all only allow filters and forbids updates" do
    message = ~r"`delete_all` does not allow `update` expressions"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, update: [set: [name: "foo"]]) |> normalize(:delete_all)
    end

    message = ~r"`delete_all` allows only `with_cte`, `where` and `join` expressions"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, order_by: p.title) |> normalize(:delete_all)
    end
  end
end
