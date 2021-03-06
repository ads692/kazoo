%%%-------------------------------------------------------------------
%%% @copyright (C) 2013-2016, 2600Hz
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(omnip_util).

-export([extract_user/1
        ,normalize_variables/1
        ,are_valid_uris/1, is_valid_uri/1
        ]).

-include("omnipresence.hrl").
-include_lib("kazoo_sip/include/kzsip_uri.hrl").

-spec extract_user(ne_binary()) -> {ne_binary(), ne_binary(), ne_binaries()}.
extract_user(User) ->
    [#uri{scheme=Proto, user=Username, domain=Realm}] = kzsip_uri:uris(User),
    {kz_util:to_binary(Proto), <<Username/binary, "@", Realm/binary>>, [Username, Realm]}.

-spec normalize_variables(kz_proplist()) -> kz_proplist().
normalize_variables(Props) ->
    [{kz_json:normalize_key(K), V} || {K, V} <- Props].

-spec are_valid_uris(ne_binaries()) -> boolean().
are_valid_uris(L) ->
    lists:all(fun is_valid_uri/1, L).

-spec is_valid_uri(ne_binary()) -> boolean().
is_valid_uri(Uri) ->
    case binary:split(Uri, <<"@">>) of
        [_User, _Host] -> 'true';
        _ -> 'false'
    end.
