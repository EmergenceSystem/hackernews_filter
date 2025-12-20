-module(hackernews_filter_app).
-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% Handler callbacks
-export([handle/1]).

-define(ALGOLIA_SEARCH_URL, "http://hn.algolia.com/api/v1/search").

%% Application behavior
start(_StartType, _StartArgs) ->
    {ok, Port} = em_filter:find_port(),
    em_filter_sup:start_link(hackernews_filter, ?MODULE, Port).

stop(_State) ->
    ok.

%% @doc Handle incoming requests from the filter server.
handle(Body) when is_binary(Body) ->
    handle(binary_to_list(Body));

handle(Body) when is_list(Body) ->
    EmbryoList = generate_embryo_list(list_to_binary(Body)),
    Response = #{embryo_list => EmbryoList},
    jsone:encode(Response);

handle(_) ->
    jsone:encode(#{error => <<"Invalid request body">>}).

generate_embryo_list(JsonBinary) ->
    case jsone:decode(JsonBinary, [{keys, atom}]) of
        Search when is_map(Search) ->
            Value = binary_to_list(maps:get(value, Search, <<"">>)),
            Timeout = list_to_integer(binary_to_list(maps:get(timeout, Search, <<"10">>))),

            SearchTypes = [
                {story, "story"},
                {comment, "comment"},
                {job, "job"},
                {show_hn, "show_hn"},
                {ask_hn, "ask_hn"}
            ],
            
            StartTime = erlang:system_time(millisecond),
            TimeoutMs = Timeout * 1000,
            
            search_all_types(SearchTypes, Value, StartTime, TimeoutMs, []);
        {error, Reason} ->
            io:format("Error decoding JSON: ~p~n", [Reason]),
            []
    end.

search_all_types([], _Query, _StartTime, _Timeout, Acc) ->
    lists:reverse(Acc);
search_all_types([{TypeAtom, TypeTag} | Rest], Query, StartTime, Timeout, Acc) ->
    CurrentTime = erlang:system_time(millisecond),
    case CurrentTime - StartTime >= Timeout of
        true ->
            lists:reverse(Acc);
        false ->
            Results = search_hn_type(TypeAtom, TypeTag, Query, Timeout div 1000),
            search_all_types(Rest, Query, StartTime, Timeout, Results ++ Acc)
    end.

search_hn_type(TypeAtom, TypeTag, Query, TimeoutSecs) ->
    EncodedQuery = uri_string:quote(Query),
    Url = lists:concat([?ALGOLIA_SEARCH_URL, "?query=", EncodedQuery, 
                        "&tags=", TypeTag, "&hitsPerPage=20"]),
    
    case httpc:request(get, {Url, []}, [{timeout, TimeoutSecs * 1000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            extract_hits_from_response(Body, TypeAtom);
        {ok, {{_, StatusCode, _}, _, _}} ->
            io:format("Algolia API returned status ~p for ~p~n", [StatusCode, TypeAtom]),
            [];
        {error, Reason} ->
            io:format("Error fetching ~p results: ~p~n", [TypeAtom, Reason]),
            []
    end.

extract_hits_from_response(JsonData, Type) ->
    try jsone:decode(JsonData) of
        ParsedJson ->
            case maps:get(<<"hits">>, ParsedJson, undefined) of
                Hits when is_list(Hits) ->
                    lists:filtermap(
                        fun(Hit) -> process_hit(Hit, Type) end,
                        Hits
                    );
                _ ->
                    []
            end
    catch
        error:Reason ->
            io:format("Failed to parse JSON response for ~p: ~p~n", [Type, Reason]),
            []
    end.

process_hit(Hit, story) ->
    try
        ObjectID = maps:get(<<"objectID">>, Hit, undefined),
        Title = maps:get(<<"title">>, Hit, undefined),
        
        case {ObjectID, Title} of
            {ID, T} when is_binary(ID), is_binary(T) ->
                Author = maps:get(<<"author">>, Hit, <<"unknown">>),
                Points = maps:get(<<"points">>, Hit, 0),
                NumComments = maps:get(<<"num_comments">>, Hit, 0),
                
                Url = <<"https://news.ycombinator.com/item?id=", ID/binary>>,

                
                ResumeStr = io_lib:format("~ts [~p pts | ~p comments] by ~ts", 
                                         [binary_to_list(T), Points, NumComments, 
                                          binary_to_list(Author)]),
                Resume = unicode:characters_to_binary(ResumeStr),
                
                {true, #{
                    properties => #{
                        <<"url">> => Url,
                        <<"resume">> => Resume,
                        <<"type">> => <<"story">>
                    }
                }};
            _ ->
                false
        end
    catch
        _:_ -> false
    end;

process_hit(Hit, comment) ->
    try
        ObjectID = maps:get(<<"objectID">>, Hit, undefined),
        StoryID = maps:get(<<"story_id">>, Hit, undefined),
        
        case {ObjectID, StoryID} of
            {ID, SID} when is_binary(ID) ->
                Author = maps:get(<<"author">>, Hit, <<"unknown">>),
                StoryTitle = maps:get(<<"story_title">>, Hit, <<"Untitled">>),
                CommentText = maps:get(<<"comment_text">>, Hit, <<>>),
                
                %% Extraire un aperçu du commentaire (100 premiers caractères)
                Preview = case byte_size(CommentText) of
                    Size when Size > 100 ->
                        <<Preview100:100/binary, _/binary>> = CommentText,
                        <<Preview100/binary, "...">>;
                    _ ->
                        CommentText
                end,
                
                Url = case SID of
                    S when is_binary(S) ->
                        <<"https://news.ycombinator.com/item?id=", S/binary, "#", ID/binary>>;
                    _ ->
                        <<"https://news.ycombinator.com/item?id=", ID/binary>>
                end,
                
                ResumeStr = io_lib:format("Comment by ~ts on \"~ts\": ~ts", 
                                         [binary_to_list(Author), 
                                          binary_to_list(StoryTitle),
                                          binary_to_list(Preview)]),
                Resume = unicode:characters_to_binary(ResumeStr),
                
                {true, #{
                    properties => #{
                        <<"url">> => Url,
                        <<"resume">> => Resume,
                        <<"type">> => <<"comment">>
                    }
                }};
            _ ->
                false
        end
    catch
        _:_ -> false
    end;

process_hit(Hit, job) ->
    try
        ObjectID = maps:get(<<"objectID">>, Hit, undefined),
        Title = maps:get(<<"title">>, Hit, undefined),
        
        case {ObjectID, Title} of
            {ID, T} when is_binary(ID), is_binary(T) ->
                Author = maps:get(<<"author">>, Hit, <<"unknown">>),
                
                Url = <<"https://news.ycombinator.com/item?id=", ID/binary>>,
                
                ResumeStr = io_lib:format("Job: ~ts (posted by ~ts)", 
                                         [binary_to_list(T), binary_to_list(Author)]),
                Resume = unicode:characters_to_binary(ResumeStr),
                
                {true, #{
                    properties => #{
                        <<"url">> => Url,
                        <<"resume">> => Resume,
                        <<"type">> => <<"job">>
                    }
                }};
            _ ->
                false
        end
    catch
        _:_ -> false
    end;

process_hit(Hit, show_hn) ->
    try
        ObjectID = maps:get(<<"objectID">>, Hit, undefined),
        Title = maps:get(<<"title">>, Hit, undefined),
        
        case {ObjectID, Title} of
            {ID, T} when is_binary(ID), is_binary(T) ->
                Author = maps:get(<<"author">>, Hit, <<"unknown">>),
                Points = maps:get(<<"points">>, Hit, 0),
                NumComments = maps:get(<<"num_comments">>, Hit, 0),
                
                Url = <<"https://news.ycombinator.com/item?id=", ID/binary>>,
                
                ResumeStr = io_lib:format("Show HN: ~ts [~p pts | ~p comments] by ~ts", 
                                         [binary_to_list(T), Points, NumComments, 
                                          binary_to_list(Author)]),
                Resume = unicode:characters_to_binary(ResumeStr),
                
                {true, #{
                    properties => #{
                        <<"url">> => Url,
                        <<"resume">> => Resume,
                        <<"type">> => <<"show_hn">>
                    }
                }};
            _ ->
                false
        end
    catch
        _:_ -> false
    end;

process_hit(Hit, ask_hn) ->
    try
        ObjectID = maps:get(<<"objectID">>, Hit, undefined),
        Title = maps:get(<<"title">>, Hit, undefined),
        
        case {ObjectID, Title} of
            {ID, T} when is_binary(ID), is_binary(T) ->
                Author = maps:get(<<"author">>, Hit, <<"unknown">>),
                Points = maps:get(<<"points">>, Hit, 0),
                NumComments = maps:get(<<"num_comments">>, Hit, 0),
                
                Url = <<"https://news.ycombinator.com/item?id=", ID/binary>>,
                
                ResumeStr = io_lib:format("Ask HN: ~ts [~p pts | ~p comments] by ~ts", 
                                         [binary_to_list(T), Points, NumComments, 
                                          binary_to_list(Author)]),
                Resume = unicode:characters_to_binary(ResumeStr),
                
                {true, #{
                    properties => #{
                        <<"url">> => Url,
                        <<"resume">> => Resume,
                        <<"type">> => <<"ask_hn">>
                    }
                }};
            _ ->
                false
        end
    catch
        _:_ -> false
    end.
