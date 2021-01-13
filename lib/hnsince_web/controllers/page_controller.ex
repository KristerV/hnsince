alias HNSince.Story, as: Story

defmodule HNSinceWeb.PageController do
  @conf Application.get_env(:hnsince, HNSince.PageView)
  use HNSinceWeb, :controller

  def index(conn, params) do
    session_visits =
      get_session(conn, :last_visits) ||
        Enum.map(2..@conf[:visits_memory_size], fn _ -> nil end) ++
          [get_session(conn, :last_visit)]

    session_last =
      case params["visit"] do
        nil -> session_visits |> List.last()
        unix -> unix |> String.to_integer() |> DateTime.from_unix!()
      end

    last_visit =
      case session_last do
        nil ->
          %{session: nil, buffered: 0, human: nil, min_hours: nil}

        %DateTime{} = dt ->
          %{
            session: dt,
            buffered:
              DateTime.add(dt, -60 * 60 * @conf[:past_buffer_hours], :second)
              |> DateTime.to_unix(),
            human: Timex.from_now(dt),
            min_hours:
              if Timex.diff(DateTime.utc_now(), dt, :hours) < @conf[:past_buffer_hours] do
                @conf[:past_buffer_hours]
              else
                nil
              end
          }
      end

    Task.start(fn ->
      url = @conf[:analytics_hook]

      if !is_nil(url) do
        case last_visit.session do
          nil ->
            HTTPoison.post(
              url <> "visits",
              "{\"visit\": 1}",
              [{"Content-Type", "application/json"}]
            )

          _session ->
            HTTPoison.post(
              url <> "visits",
              "{\"returning\": 1}",
              [{"Content-Type", "application/json"}]
            )
        end

        if Timex.diff(DateTime.utc_now(), DateTime.from_unix!(last_visit.buffered), :hours) > 24 and
             is_nil(params["visit"]) and
             !is_nil(last_visit.session) do
          HTTPoison.post(
            url <> "unique",
            "{\"unique day\": 1}",
            [{"Content-Type", "application/json"}]
          )
        end
      end
    end)

    previous_visits =
      for visit <- session_visits, !is_nil(visit) do
        %{
          human: Timex.from_now(visit),
          unix_utc: DateTime.to_unix(visit)
        }
      end
      |> Enum.reverse()
      |> Enum.reduce([], fn x, acc ->
        h = x.human

        case List.last(acc) do
          nil -> [x]
          %{:human => ^h} -> acc
          _ -> acc ++ [x]
        end
      end)
      |> Enum.drop(1)

    conn =
      if is_nil(params["visit"]) do
        session_visits
        |> Enum.concat([DateTime.utc_now()])
        |> (&Enum.drop(&1, length(&1) - @conf[:visits_memory_size])).()
        |> (&put_session(conn, :last_visits, &1)).()
      else
        conn
      end

    stories =
      case last_visit.buffered do
        0 -> HNSince.AllTimeStoriesCache.get()
        buffered -> Story.get_since(buffered, @conf[:stories_visible])
      end
      |> Enum.map(fn s ->
        domain =
          case s.url do
            nil -> nil
            url -> URI.parse(url).authority
          end

        past =
          with {:ok, t} = DateTime.from_unix(s.time) do
            Timex.from_now(t)
          end

        Map.merge(s, %{
          domain: domain,
          past: past
        })
      end)

    render(conn, "index.html",
      last_visit: last_visit.human,
      min_hours: last_visit.min_hours,
      stories: stories,
      previous_visits: previous_visits,
      visit_override: params["visit"]
    )
  end
end
