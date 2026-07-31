defmodule Delimited.Bench.Fixture do
  @moduledoc false

  # Shared data and settings for the benchmarks.
  #
  # Rows are built from their own index rather than at random, so two runs on
  # the same machine measure the same work and a saved run stays comparable to a
  # later one. Nothing here is seeded, because a seeded generator still depends
  # on the generator's own version.

  @rows String.to_integer(System.get_env("BENCH_ROWS", "10000"))
  @time String.to_integer(System.get_env("BENCH_TIME", "3"))
  @warmup String.to_integer(System.get_env("BENCH_WARMUP", "1"))

  @doc "How many rows each fixture holds."
  def rows, do: @rows

  @doc """
  Benchee settings.

  `BENCH_TIME` and `BENCH_ROWS` shorten a run when the point is to check that
  the benchmarks still work rather than to measure anything. `BENCH_SAVE` and
  `BENCH_LOAD` name a file to compare one run against another, which is how a
  change is shown not to have cost anything.
  """
  def options(extra \\ []) do
    Keyword.merge(
      [
        time: @time,
        warmup: @warmup,
        print: [fast_warning: false]
      ] ++ save() ++ load(),
      extra
    )
  end

  defp save do
    case System.get_env("BENCH_SAVE") do
      nil -> []
      tag -> [save: [path: "bench/snapshots/#{tag}.benchee", tag: tag]]
    end
  end

  defp load do
    case System.get_env("BENCH_LOAD") do
      nil -> []
      tag -> [load: "bench/snapshots/#{tag}.benchee"]
    end
  end

  @doc "A comma-separated file with no cell needing quotes."
  def plain_csv(count \\ @rows) do
    build(count, &plain_row/1, "id,name,city,amount,rate,joined,active,tier\n")
  end

  @doc "The same file with every text cell quoted and holding a comma."
  def quoted_csv(count \\ @rows) do
    build(count, &quoted_row/1, "id,name,city,amount,rate,joined,active,tier\n")
  end

  @doc "The same columns as fixed-width records."
  def fixed_file(count \\ @rows) do
    build(count, &fixed_row/1, "")
  end

  defp build(count, row, header) do
    IO.iodata_to_binary([header, Enum.map(1..count, row)])
  end

  defp plain_row(index) do
    [
      Integer.to_string(index),
      ",Name ",
      Integer.to_string(rem(index, 997)),
      ",",
      city(index),
      ",",
      Integer.to_string(rem(index, 100_000)),
      ",",
      Float.to_string(rem(index, 1000) / 10),
      ",",
      date(index),
      ",",
      if(rem(index, 2) == 0, do: "true", else: "false"),
      ",",
      tier(index),
      "\n"
    ]
  end

  defp quoted_row(index) do
    [
      Integer.to_string(index),
      ",\"Name, ",
      Integer.to_string(rem(index, 997)),
      "\",\"",
      city(index),
      ", UK\",",
      Integer.to_string(rem(index, 100_000)),
      ",",
      Float.to_string(rem(index, 1000) / 10),
      ",",
      date(index),
      ",",
      if(rem(index, 2) == 0, do: "true", else: "false"),
      ",",
      tier(index),
      "\n"
    ]
  end

  #      1-8|9-28|29-48|49-56|57-64|65-74|75|76-78
  defp fixed_row(index) do
    [
      String.pad_leading(Integer.to_string(index), 8, "0"),
      String.pad_trailing("Name #{rem(index, 997)}", 20),
      String.pad_trailing(city(index), 20),
      String.pad_leading(Integer.to_string(rem(index, 100_000)), 8, "0"),
      # A float is right-aligned by default, so the fixture pads it that way.
      String.pad_leading(Float.to_string(rem(index, 1000) / 10), 8),
      date(index),
      if(rem(index, 2) == 0, do: "1", else: "0"),
      tier(index),
      "\n"
    ]
  end

  @cities ~w(Leeds York Bath Hull Ely Perth Truro Derby)
  @tiers ~w(one two thr)

  defp city(index), do: Enum.at(@cities, rem(index, length(@cities)))
  defp tier(index), do: Enum.at(@tiers, rem(index, length(@tiers)))

  defp date(index) do
    ~D[2020-01-01] |> Date.add(rem(index, 1500)) |> Date.to_iso8601()
  end

  @doc "Writes `contents` to a temporary path and hands it to `function`."
  def with_file(contents, function) do
    path = Path.join(System.tmp_dir!(), "delimited-bench-#{:erlang.phash2(contents)}.txt")
    File.write!(path, contents)

    try do
      function.(path)
    after
      File.rm(path)
    end
  end
end

defmodule Delimited.Bench.Row do
  @moduledoc false
  # Eight columns of mixed types: what casting costs on a realistic row.

  use Delimited.Schema

  delimited_schema do
    field :id, :integer
    field :name, :string
    field :city, :string
    field :amount, :integer
    field :rate, :float
    field :joined, :date
    field :active, :boolean
    field :tier, {:enum, [one: "one", two: "two", three: "thr"]}
  end
end

defmodule Delimited.Bench.TextRow do
  @moduledoc false
  # The same eight columns read as text, so that the difference between this and
  # Row is what the types cost and nothing else.

  use Delimited.Schema

  delimited_schema do
    field :id, :string
    field :name, :string
    field :city, :string
    field :amount, :string
    field :rate, :string
    field :joined, :string
    field :active, :string
    field :tier, :string
  end
end

defmodule Delimited.Bench.FixedRow do
  @moduledoc false

  use Delimited.Schema

  delimited_schema :fixed do
    field :id, :integer, at: 1..8, pad: ?0
    field :name, :string, at: 9..28
    field :city, :string, at: 29..48
    field :amount, :integer, at: 49..56, pad: ?0
    field :rate, :float, at: 57..64
    field :joined, :date, at: 65..74
    field :active, {:enum, [true: "1", false: "0"]}, at: 75..75
    field :tier, {:enum, [one: "one", two: "two", three: "thr"]}, at: 76..78
  end
end

defmodule Delimited.Bench.IsoDates do
  @moduledoc false

  use Delimited.Schema

  delimited_schema do
    field :a, :date
    field :b, :date
    field :c, :date
  end
end

defmodule Delimited.Bench.FormattedDates do
  @moduledoc false

  use Delimited.Schema

  delimited_schema do
    field :a, :date, format: "%d/%m/%Y"
    field :b, :date, format: "%d/%m/%Y"
    field :c, :date, format: "%d/%m/%Y"
  end
end

defmodule Delimited.Bench.Part do
  @moduledoc false

  use Delimited.Schema

  delimited_schema do
    field :street, :string
    field :city, :string
  end
end

defmodule Delimited.Bench.Flat do
  @moduledoc false

  use Delimited.Schema

  delimited_schema do
    field :id, :integer
    field :billing_street, :string
    field :billing_city, :string
    field :shipping_street, :string
    field :shipping_city, :string
  end
end

defmodule Delimited.Bench.Embedded do
  @moduledoc false
  # The same five columns, declared through embeds. Reading these two should
  # cost the same, because an embed is expanded when the schema compiles.

  use Delimited.Schema

  delimited_schema do
    field :id, :integer
    embeds_one :billing, Delimited.Bench.Part, prefix: "billing_"
    embeds_one :shipping, Delimited.Bench.Part, prefix: "shipping_"
  end
end
