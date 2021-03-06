%%%-------------------------------------------------------------------
%%% @copyright (C) 2012-2016, 2600Hz Inc
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%   Peter Defebvre
%%%   Ben Wann
%%%-------------------------------------------------------------------
-module(bh_conference).

-export([handle_event/2
        ,add_amqp_binding/2, rm_amqp_binding/2
        ]).

-include("blackhole.hrl").

-spec handle_event(bh_context:context(), kz_json:object()) -> 'ok'.
handle_event(Context, EventJObj) ->
    lager:debug("handling conference event ~s", [get_response_key(EventJObj)]),
    blackhole_data_emitter:emit(bh_context:websocket_pid(Context)
                               ,get_response_key(EventJObj)
                               ,kz_json:normalize_jobj(EventJObj)
                               ).

-spec add_amqp_binding(ne_binary(), bh_context:context()) -> 'ok'.
add_amqp_binding(<<"conference.command.", ConfId/binary>>, _Context) ->
    blackhole_listener:add_binding('conference', command_binding_options(ConfId));
add_amqp_binding(<<"conference.event.", Binding/binary>>, _Context) ->
    case binary:split(Binding, <<".">>, ['global']) of
        [ConfId, CallId] ->
            blackhole_listener:add_binding('conference', event_binding_options(ConfId, CallId));
        _Else -> lager:debug("invalid conference event bind: ~s", [Binding])
    end;
add_amqp_binding(Binding, _Context) ->
    lager:debug("unmatched binding ~p", [Binding]).

-spec rm_amqp_binding(ne_binary(), bh_context:context()) -> 'ok'.
rm_amqp_binding(<<"conference.command.", ConfId/binary>>, _Context) ->
    blackhole_listener:remove_binding('conference', command_binding_options(ConfId));
rm_amqp_binding(<<"conference.event.", Binding/binary>>, _Context) ->
    case binary:split(Binding, <<".">>, ['global']) of
        [ConfId, CallId] ->
            blackhole_listener:remove_binding('conference', event_binding_options(ConfId, CallId));
        _Else -> lager:debug("invalid conference event unbind: ~s", [Binding])
    end;
rm_amqp_binding(Binding, _Context) ->
    lager:debug("unmatched binding ~p", [Binding]).

%%%===================================================================
%%% Internal functions
%%%==================================================================
-spec get_response_key(kz_json:object()) -> ne_binary().
get_response_key(JObj) ->
    kz_json:get_first_defined([<<"Application-Name">>, <<"Event-Name">>], JObj).

-spec command_binding_options(ne_binary()) -> kz_proplist().
command_binding_options(ConfId) ->
    [{'conference', ConfId}
    ,{'restrict_to', ['command']}
    ,'federate'
    ].

-spec event_binding_options(ne_binary(), ne_binary()) -> kz_proplist().
event_binding_options(ConfId, CallId) ->
    [{'conference', {ConfId, CallId}}
    ,{'restrict_to', ['event']}
    ,'federate'
    ].
