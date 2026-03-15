%%%-------------------------------------------------------------------
%%% @doc Hacker News search agent.
%%%
%%% Combines two data sources for complementary coverage:
%%%
%%%   Algolia API — full-text search over the entire HN archive.
%%%                 Returns stories, comments, jobs, Show HN, Ask HN
%%%                 with scores, comment counts and author info.
%%%
%%%   hnrss.org   — live RSS feeds (frontpage, newest, best).
%%%                 Catches very recent items not yet indexed by Algolia
%%%                 and items that match the query in their title.
%%%
%%% Both sources run in parallel. Deduplication by URL is handled
%%% upstream by emquest_handler, so both lists are returned as-is.
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, NewMemory}.
%%% Memory schema: #{seen => #{binary_url => true}}.
%%% @end
%%%-------------------------------------------------------------------
-module(hackernews_filter_app).
-behaviour(application).

-include_lib("xmerl/include/xmerl.hrl").

-export([start/2, stop/1]).
-export([handle/2]).

-define(ALGOLIA_URL, "http://hn.algolia.com/api/v1/search").

-define(RSS_FEEDS, [
    "https://hnrss.org/frontpage",
    "https://hnrss.org/newest?points=100",
    "https://hnrss.org/best",
    "https://hnrss.org/ask",
    "https://hnrss.org/show"
]).

-define(ALGOLIA_TYPES, [story, comment, job, show_hn, ask_hn]).

-define(CAPABILITIES, [
    <<"hackernews">>,
    <<"tech_news">>,
    <<"startups">>,
    <<"programming">>,
    <<"community">>
]).

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_agent(hackernews_filter, ?MODULE, #{
        capabilities => ?CAPABILITIES,
        memory       => ets
    }).

stop(_State) ->
    em_filter:stop_agent(hackernews_filter).

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    Seen    = maps:get(seen, Memory, #{}),
    Embryos = generate_embryo_list(Body),
    Fresh   = [E || E <- Embryos, not maps:is_key(url_of(E), Seen)],
    NewSeen = lists:foldl(fun(E, Acc) ->
        Acc#{url_of(E) => true}
    end, Seen, Fresh),
    {Fresh, Memory#{seen => NewSeen}};

handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Aggregation — Algolia + RSS in parallel
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout} = extract_params(JsonBinary),
    Parent = self(),

    %% Spawn both sources concurrently.
    spawn(fun() ->
        Parent ! {algolia_results, search_algolia(Value, Timeout)}
    end),
    spawn(fun() ->
        Parent ! {rss_results, search_rss(Value, Timeout)}
    end),

    %% Collect both results within the overall timeout.
    DeadlineMs = erlang:system_time(millisecond) + Timeout * 1000,
    AlgoliaResults = receive_results(algolia_results, DeadlineMs),
    RssResults     = receive_results(rss_results,     DeadlineMs),

    AlgoliaResults ++ RssResults.

receive_results(Tag, DeadlineMs) ->
    Remaining = max(0, DeadlineMs - erlang:system_time(millisecond)),
    receive
        {Tag, Results} -> Results
    after Remaining    -> []
    end.

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            %% Accept both "value" and "query" keys for compatibility.
            Value   = binary_to_list(maps:get(<<"value">>, Map,
                          maps:get(<<"query">>, Map, <<"">>))),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Value, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 10}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10}
    end.

%%====================================================================
%% Algolia API
%%====================================================================

search_algolia(Query, TimeoutSecs) ->
    lists:flatmap(fun(Type) ->
        search_hn_type(Type, Query, TimeoutSecs)
    end, ?ALGOLIA_TYPES).

search_hn_type(Type, Query, TimeoutSecs) ->
    Tag = atom_to_tag(Type),
    Url = lists:concat([?ALGOLIA_URL,
                        "?query=", uri_string:quote(Query),
                        "&tags=",  Tag,
                        "&hitsPerPage=20"]),
    case httpc:request(get, {Url, []},
                       [{timeout, TimeoutSecs * 1000}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_hits(Body, Type);
        _ ->
            []
    end.

atom_to_tag(story)   -> "story";
atom_to_tag(comment) -> "comment";
atom_to_tag(job)     -> "job";
atom_to_tag(show_hn) -> "show_hn";
atom_to_tag(ask_hn)  -> "ask_hn".

parse_hits(JsonData, Type) ->
    try json:decode(JsonData) of
        #{<<"hits">> := Hits} when is_list(Hits) ->
            lists:filtermap(fun(H) -> process_hit(H, Type) end, Hits);
        _ -> []
    catch
        _:_ -> []
    end.

process_hit(Hit, story) ->
    case {maps:get(<<"objectID">>, Hit, undefined),
          maps:get(<<"title">>,    Hit, undefined)} of
        {Id, T} when is_binary(Id), is_binary(T) ->
            Author   = maps:get(<<"author">>,       Hit, <<"unknown">>),
            Points   = maps:get(<<"points">>,       Hit, 0),
            Comments = maps:get(<<"num_comments">>, Hit, 0),
            Url      = <<"https://news.ycombinator.com/item?id=", Id/binary>>,
            Resume   = fmt("~ts [~p pts | ~p comments] by ~ts",
                           [T, Points, Comments, Author]),
            {true, embryo(Url, Resume)};
        _ -> false
    end;

process_hit(Hit, comment) ->
    case maps:get(<<"objectID">>, Hit, undefined) of
        Id when is_binary(Id) ->
            Author  = maps:get(<<"author">>,       Hit, <<"unknown">>),
            StoryT  = maps:get(<<"story_title">>,  Hit, <<"Untitled">>),
            Text    = maps:get(<<"comment_text">>, Hit, <<>>),
            Preview = truncate(Text, 100),
            %% story_id is an integer in the Algolia API response.
            Url = case maps:get(<<"story_id">>, Hit, undefined) of
                S when is_integer(S) ->
                    SBin = integer_to_binary(S),
                    <<"https://news.ycombinator.com/item?id=", SBin/binary,
                      "#", Id/binary>>;
                _ ->
                    <<"https://news.ycombinator.com/item?id=", Id/binary>>
            end,
            Resume = fmt("Comment by ~ts on \"~ts\": ~ts",
                         [Author, StoryT, Preview]),
            {true, embryo(Url, Resume)};
        _ -> false
    end;

process_hit(Hit, job) ->
    case {maps:get(<<"objectID">>, Hit, undefined),
          maps:get(<<"title">>,    Hit, undefined)} of
        {Id, T} when is_binary(Id), is_binary(T) ->
            Author = maps:get(<<"author">>, Hit, <<"unknown">>),
            Url    = <<"https://news.ycombinator.com/item?id=", Id/binary>>,
            Resume = fmt("Job: ~ts (posted by ~ts)", [T, Author]),
            {true, embryo(Url, Resume)};
        _ -> false
    end;

process_hit(Hit, show_hn) ->
    case {maps:get(<<"objectID">>, Hit, undefined),
          maps:get(<<"title">>,    Hit, undefined)} of
        {Id, T} when is_binary(Id), is_binary(T) ->
            Author   = maps:get(<<"author">>,       Hit, <<"unknown">>),
            Points   = maps:get(<<"points">>,       Hit, 0),
            Comments = maps:get(<<"num_comments">>, Hit, 0),
            Url      = <<"https://news.ycombinator.com/item?id=", Id/binary>>,
            Resume   = fmt("Show HN: ~ts [~p pts | ~p comments] by ~ts",
                           [T, Points, Comments, Author]),
            {true, embryo(Url, Resume)};
        _ -> false
    end;

process_hit(Hit, ask_hn) ->
    case {maps:get(<<"objectID">>, Hit, undefined),
          maps:get(<<"title">>,    Hit, undefined)} of
        {Id, T} when is_binary(Id), is_binary(T) ->
            Author   = maps:get(<<"author">>,       Hit, <<"unknown">>),
            Points   = maps:get(<<"points">>,       Hit, 0),
            Comments = maps:get(<<"num_comments">>, Hit, 0),
            Url      = <<"https://news.ycombinator.com/item?id=", Id/binary>>,
            Resume   = fmt("Ask HN: ~ts [~p pts | ~p comments] by ~ts",
                           [T, Points, Comments, Author]),
            {true, embryo(Url, Resume)};
        _ -> false
    end.

%%====================================================================
%% RSS feeds (hnrss.org)
%%====================================================================

search_rss(Query, TimeoutSecs) ->
    StartTime = erlang:system_time(millisecond),
    search_feeds(?RSS_FEEDS, string:lowercase(Query),
                 StartTime, TimeoutSecs * 1000, []).

search_feeds([], _Query, _Start, _Timeout, Acc) ->
    lists:reverse(Acc);
search_feeds([FeedUrl | Rest], Query, Start, Timeout, Acc) ->
    case erlang:system_time(millisecond) - Start >= Timeout of
        true  -> lists:reverse(Acc);
        false ->
            NewAcc = fetch_and_filter_feed(FeedUrl, Query, Start, Timeout, Acc),
            search_feeds(Rest, Query, Start, Timeout, NewAcc)
    end.

fetch_and_filter_feed(FeedUrl, Query, Start, Timeout, Acc) ->
    case httpc:request(get, {FeedUrl, []},
                       [{timeout, 5000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            case xmerl_scan:string(binary_to_list(Body)) of
                {Doc, _} ->
                    Items = xmerl_xpath:string("//item", Doc),
                    process_items(Items, Query, Start, Timeout, Acc);
                _ ->
                    Acc
            end;
        _ ->
            Acc
    end.

process_items([], _Query, _Start, _Timeout, Acc) ->
    Acc;
process_items([Item | Rest], Query, Start, Timeout, Acc) ->
    case erlang:system_time(millisecond) - Start >= Timeout of
        true  -> Acc;
        false ->
            NewAcc = case process_item(Item, Query) of
                {ok, E} -> [E | Acc];
                skip    -> Acc
            end,
            process_items(Rest, Query, Start, Timeout, NewAcc)
    end.

process_item(Item, Query) ->
    Title = xml_text(xmerl_xpath:string("./title/text()",       Item)),
    Link  = xml_text(xmerl_xpath:string("./link/text()",        Item)),
    Desc  = xml_text(xmerl_xpath:string("./description/text()", Item)),
    Matches =
        string:str(string:lowercase(Title), Query) > 0 orelse
        string:str(string:lowercase(Link),  Query) > 0 orelse
        string:str(string:lowercase(Desc),  Query) > 0,
    case Matches of
        true ->
            {ok, embryo(list_to_binary(Link),
                        unicode:characters_to_binary(Title))};
        false ->
            skip
    end.

%%====================================================================
%% Shared helpers
%%====================================================================

-spec embryo(binary(), binary()) -> map().
embryo(Url, Resume) ->
    #{<<"properties">> => #{<<"url">> => Url, <<"resume">> => Resume}}.

fmt(F, Args) ->
    unicode:characters_to_binary(io_lib:format(F, Args)).

truncate(Bin, Max) when byte_size(Bin) > Max ->
    <<Part:Max/binary, _/binary>> = Bin,
    <<Part/binary, "...">>;
truncate(Bin, _Max) ->
    Bin.

xml_text([#xmlText{value = V} | _]) -> V;
xml_text(_)                          -> "".

-spec url_of(map()) -> binary().
url_of(#{<<"properties">> := #{<<"url">> := Url}}) -> Url;
url_of(_) -> <<>>.
