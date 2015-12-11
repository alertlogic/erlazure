-module(erlazure_insights).

-export([
        get_events/5,
        get_events_all/4,
        create_time_bounded_filter/2
    ]).

-include("erlazure.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-export([test_url_construction/0]).
-endif.

-type datetime() :: {{number(), number(), number},
    {number(), number(), number()}}.

-type offset() :: {seconds | minutes | hours, number()}.

-spec get_events_all(string(), string(), string(), #azure_config{}) ->
    {ok, list()} | {{error, term()}, {accumulated, list()}}.
get_events_all(SubscriptionId, Filter, Select, Config=#azure_config{}) ->
    {ok, Values, NextToken} = get_events(SubscriptionId, Filter, Select, Config, []),
    case NextToken of
        undefined -> {ok, Values};
        _ -> follow_token(binary_to_list(NextToken), Values, Config)
    end.

-spec get_events(string(), string(), string(), #azure_config{}, string()) ->
    {ok, list(), undefined | binary()}.
get_events(SubscriptionId, Filter, Select, Config=#azure_config{}, NextToken) ->
    case NextToken of
        [] ->
            case http_request(SubscriptionId, Filter, Select, Config) of
                {ok, _Values, _NextToken} = Response ->
                    Response;
                {error, _Reason} = ErrorCase ->
                    ErrorCase
            end;
        _ -> follow_token(NextToken, [], Config)
    end.

-spec follow_token(string(), list(), #azure_config{}) ->
    {ok, list()} | {{error, term()}, {accumulated, list()}}.
follow_token(Url, DataAcc, Config) ->
    Result = request_api(Url, Config),
    case Result of
        {ok, Data, undefined} ->
            {ok, Data};
        {ok, Data, NextToken} ->
            follow_token(binary_to_list(NextToken), [DataAcc | Data], Config);
        {error, _Reason} = ErrorCase ->
            {ErrorCase, {accumulated, DataAcc}}
    end.

request_api(Url, Config) ->
    Response = httpc:request(get, {Url, construct_headers(Config)}, [], []),

    case Response of
        {ok, {{_Version, 200, _Phrase}, _Headers, Body}} ->
            DecodedBody = jsx:decode(list_to_binary(Body)),
            NextLink = proplists:get_value(<<"nextLink">>, DecodedBody, undefined),
            Values = proplists:get_value(<<"value">>, DecodedBody, undefined),
            {ok, Values, NextLink};
        {ok, {{_Version, Code, Phrase}, _Headers, Body}} ->
            {error, {Code, {Phrase, Body}}};
        {error, _Reason} = ErrorCase ->
            ErrorCase
    end.

http_request(SubscriptionId, Filter, Select, Config) ->
    URL = "https://management.azure.com/subscriptions/" ++
    SubscriptionId ++
    "/providers/microsoft.insights/eventtypes/management/values?" ++ "api-version=2014-04-01" ++ 
    "&%24filter=" ++ Filter ++
    "&%24select=" ++ Select,
    request_api(URL, Config).

-spec create_time_bounded_filter(string(), string()) -> string().
create_time_bounded_filter(TS1, TS2) ->
    Filter = http_uri:encode("eventTimestamp ge '" ++
        TS1  ++
    "' and eventTimestamp le '" ++
    TS2 ++ "'"),
    Filter.

construct_headers(Config) ->
    [{"Authorization", "Bearer " ++ Config#azure_config.auth_token},
        {"Accept", "application/json"}].

-ifdef(TEST).

test_url_construction() ->
    
    ToDateTime = {{2016, 2, 3}, {14, 23, 57}},

    ToTimestamp = get_time_offset_as_timestamp(ToDateTime, {seconds, 0}),
    FromTimestamp = get_time_offset_as_timestamp(ToDateTime, {hours, 24}),
    Filter = create_time_bounded_filter(FromTimestamp, ToTimestamp),
    Select = "I%20am%20selecting%20something",

    SubId = "SubId",
    Config = #azure_config{auth_token="Token"},

    meck:new(httpc, []),
    meck:expect(httpc, request, 
        fun(get, {Url, _}, _, _) -> 

                TestUrl = "https://management.azure.com/subscriptions/" ++ 
                SubId ++ 
                "/providers/microsoft.insights/eventtypes/management/values?api-version=2014-04-01&" ++
                "%24filter=eventTimestamp%20ge%20%272016-02-02T14%3A23%3A57Z%27%20and%20eventTimestamp%20le%20%272016-02-03T14%3A23%3A57Z%27" ++ 
                "&%24select=I%20am%20selecting%20something",

                true = (TestUrl == Url),
                {ok, {{"version", 401, "Phrase"}, "Headers", "Body"}}
        end
    ),

    http_request(SubId, Filter, Select, Config),
    meck:unload(httpc),
    ok.

-endif.
