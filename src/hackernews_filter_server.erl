%%%-------------------------------------------------------------------
%%% @doc hackernews_filter gen_server.
%%%
%%% Registered as `hackernews_filter_server'. Handles HTTP query requests from
%%% em_filter_http by delegating to hackernews_filter_app:handle/2.
%%%
%%% The gen_server State carries the Memory map so caching filters
%%% retain state across requests.
%%% @end
%%%-------------------------------------------------------------------
-module(hackernews_filter_server).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    {ok, #{}}.

handle_call({http_query, Query}, _From, Memory) ->
    try
        {Result, NewMemory} = hackernews_filter_app:handle(Query, Memory),
        Encoded = iolist_to_binary(json:encode(Result)),
        {reply, {ok, Encoded}, NewMemory}
    catch E:R ->
        logger:error("[hackernews_filter] handler error ~p:~p", [E, R]),
        {reply, {error, handler_failed}, Memory}
    end;
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
