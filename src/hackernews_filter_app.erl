%%%-------------------------------------------------------------------
%%% @doc Hacker News search filter using the Algolia HN API.
%%%
%%% Searches stories, comments, jobs, Show HN and Ask HN posts
%%% and returns them as embryo maps.
%%% @end
%%%-------------------------------------------------------------------
-module(hackernews_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/1]).

-define(ALGOLIA_URL, "http://hn.algolia.com/api/v1/search").

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_filter(hackernews_filter, ?MODULE).

stop(_State) ->
    em_filter:stop_filter(hackernews_filter).

%%====================================================================
%% Filter handler — returns a list of embryo maps
%%====================================================================

handle(Body) when is_binary(Body) ->
    generate_embryo_list(Body);
handle(_) ->
    [].

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout} = extract_params(JsonBinary),
    Types     = [story, comment, job, show_hn, ask_hn],
    StartTime = erlang:system_time(millisecond),
    search_all_types(Types, Value, StartTime, Timeout * 1000, []).

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value   = binary_to_list(maps:get(<<"value">>,   Map, <<"">>)),
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

search_all_types([], _Query, _Start, _Timeout, Acc) ->
    lists:reverse(Acc);
search_all_types([Type | Rest], Query, Start, Timeout, Acc) ->
    case erlang:system_time(millisecond) - Start >= Timeout of
        true  -> lists:reverse(Acc);
        false ->
            Results = search_hn_type(Type, Query, Timeout div 1000),
            search_all_types(Rest, Query, Start, Timeout, Results ++ Acc)
    end.

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

%%--------------------------------------------------------------------
%% Response parsing
%%--------------------------------------------------------------------

parse_hits(JsonData, Type) ->
    try json:decode(JsonData) of
        #{<<"hits">> := Hits} when is_list(Hits) ->
            lists:filtermap(fun(H) -> process_hit(H, Type) end, Hits);
        _ -> []
    catch
        _:_ -> []
    end.

%%--------------------------------------------------------------------
%% Per-type hit processing
%%--------------------------------------------------------------------

process_hit(Hit, story) ->
    case {maps:get(<<"objectID">>, Hit, undefined),
          maps:get(<<"title">>,    Hit, undefined)} of
        {Id, T} when is_binary(Id), is_binary(T) ->
            Author  = maps:get(<<"author">>,       Hit, <<"unknown">>),
            Points  = maps:get(<<"points">>,       Hit, 0),
            Comments= maps:get(<<"num_comments">>, Hit, 0),
            Url     = <<"https://news.ycombinator.com/item?id=", Id/binary>>,
            Resume  = fmt("~ts [~p pts | ~p comments] by ~ts",
                          [T, Points, Comments, Author]),
            {true, embryo(Url, Resume)};
        _ -> false
    end;

process_hit(Hit, comment) ->
    case maps:get(<<"objectID">>, Hit, undefined) of
        Id when is_binary(Id) ->
            Author  = maps:get(<<"author">>,      Hit, <<"unknown">>),
            StoryT  = maps:get(<<"story_title">>, Hit, <<"Untitled">>),
            Text    = maps:get(<<"comment_text">>,Hit, <<>>),
            Preview = truncate(Text, 100),
            StoryId = maps:get(<<"story_id">>,    Hit, undefined),
            Url = case StoryId of
                S when is_binary(S) ->
                    <<"https://news.ycombinator.com/item?id=", S/binary,
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

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

embryo(Url, Resume) ->
    #{<<"properties">> => #{<<"url">> => Url, <<"resume">> => Resume}}.

fmt(F, Args) ->
    unicode:characters_to_binary(io_lib:format(F, Args)).

truncate(Bin, Max) when byte_size(Bin) > Max ->
    <<Part:Max/binary, _/binary>> = Bin,
    <<Part/binary, "...">>;
truncate(Bin, _Max) ->
    Bin.
