%%%-------------------------------------------------------------------
%%% @doc Open WebUI agent.
%%%
%%% Sends the query to an Open WebUI instance (OpenAI-compatible API)
%%% and returns the answer as a single embryo map.
%%%
%%% Maintains a conversation memory (list of {query, answer} pairs)
%%% so the LLM can reference prior exchanges in its context window.
%%% Memory is kept in ETS so it survives worker restarts.
%%%
%%% === Environment variables ===
%%%
%%%   OPENWEBUI_ENDPOINT  Base URL of the Open WebUI instance (required).
%%%                       e.g. https://myinstance.example.com
%%%   OPENWEBUI_API_KEY   Bearer token / API key (required).
%%%   OPENWEBUI_MODEL     Model name to use (optional, default: Qwen/Qwen3-8B-AWQ).
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, NewMemory}.
%%% Memory schema: #{history => [{QueryBin, AnswerBin}]} (newest last).
%%% @end
%%%-------------------------------------------------------------------
-module(openwebui_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(MAX_HISTORY, 5).
-define(DEFAULT_MODEL, <<"Qwen/Qwen3-8B-AWQ">>).
-define(CHAT_PATH, "/api/chat/completions").

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"openwebui">>, <<"llm">>,
                                      <<"summarize">>, <<"generate">>,
                                      <<"local_ai">>].

%%====================================================================
%% Application lifecycle
%%====================================================================

start(_Type, _Args) ->
    case openwebui_filter_sup:start_link() of
        {ok, Pid} ->
            ok = start_pop_and_http(),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(openwebui_filter_query_listener),
    catch em_pop_sup:stop_node(openwebui_filter),
    ok.

%%====================================================================
%% Internal
%%====================================================================

start_pop_and_http() ->
    PopPort   = application:get_env(openwebui_filter, pop_port,   9484),
    QueryPort = application:get_env(openwebui_filter, query_port, 9485),
    Seeds     = application:get_env(openwebui_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(openwebui_filter),
    catch cowboy:stop_listener(openwebui_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(openwebui_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(
        fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end,
        Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => openwebui_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(openwebui_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[openwebui_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

handle(Body, Memory) when is_binary(Body) ->
    Value = extract_value(Body),
    case Value of
        "" -> {[], Memory};
        _  ->
            case get_config() of
                {error, Reason} ->
                    io:format("[openwebui] config error: ~p~n", [Reason]),
                    {[], Memory};
                Config ->
                    History  = maps:get(history, Memory, []),
                    ValueBin = unicode:characters_to_binary(Value, unicode, utf8),
                    Messages = history_to_messages(History, ValueBin),
                    case do_chat(Messages, Config) of
                        {ok, AnswerBin} ->
                            Embryo     = #{<<"properties">> => #{<<"resume">> => AnswerBin}},
                            NewHistory = trim_history(
                                History ++ [{ValueBin, AnswerBin}],
                                ?MAX_HISTORY),
                            {[Embryo], Memory#{history => NewHistory}};
                        {error, Reason} ->
                            io:format("[openwebui] chat failed: ~p~n", [Reason]),
                            {[], Memory}
                    end
            end
    end;

handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Internal helpers
%%====================================================================

get_config() ->
    case {os:getenv("OPENWEBUI_ENDPOINT"), os:getenv("OPENWEBUI_API_KEY")} of
        {false, _} -> {error, missing_endpoint};
        {_, false} -> {error, missing_api_key};
        {Endpoint, Key} ->
            Model = case os:getenv("OPENWEBUI_MODEL") of
                false -> ?DEFAULT_MODEL;
                M     -> list_to_binary(M)
            end,
            #{
                endpoint => Endpoint ++ ?CHAT_PATH,
                api_key  => list_to_binary(Key),
                model    => Model
            }
    end.

do_chat(Messages, #{endpoint := Endpoint, api_key := ApiKey, model := Model}) ->
    ok = ensure_started(),
    Payload     = #{<<"model">> => Model, <<"messages">> => Messages, <<"stream">> => false},
    JsonPayload = iolist_to_binary(json:encode(Payload)),
    Headers     = [{"authorization", "Bearer " ++ binary_to_list(ApiKey)}],
    Request     = {Endpoint, Headers, "application/json", JsonPayload},
    case httpc:request(post, Request,
                       [{ssl, [{verify, verify_peer},
                               {cacerts, public_key:cacerts_get()}]}],
                       []) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_response(Body);
        {ok, {{_, StatusCode, _}, _, Body}} ->
            {error, {http_error, StatusCode, Body}};
        {error, Reason} ->
            {error, {request_failed, Reason}}
    end.

parse_response(Body) ->
    try
        Json     = json:decode(iolist_to_binary(Body)),
        [Choice | _] = maps:get(<<"choices">>, Json),
        Message  = maps:get(<<"message">>, Choice),
        {ok, maps:get(<<"content">>, Message)}
    catch
        _:_ -> {error, parse_failed}
    end.

history_to_messages(History, CurrentQuery) ->
    HistoryMsgs = lists:flatmap(fun({Q, A}) ->
        [
            #{<<"role">> => <<"user">>,      <<"content">> => Q},
            #{<<"role">> => <<"assistant">>, <<"content">> => A}
        ]
    end, History),
    HistoryMsgs ++ [#{<<"role">> => <<"user">>, <<"content">> => CurrentQuery}].

extract_value(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            binary_to_list(maps:get(<<"value">>, Map,
                maps:get(<<"query">>, Map, <<"">>)));
        _ ->
            binary_to_list(JsonBinary)
    catch
        _:_ -> binary_to_list(JsonBinary)
    end.

trim_history(History, Max) ->
    Len = length(History),
    case Len > Max of
        true  -> lists:nthtail(Len - Max, History);
        false -> History
    end.

ensure_started() ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    ok.
