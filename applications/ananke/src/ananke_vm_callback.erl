%%%-------------------------------------------------------------------
%%% @copyright (C) 2015-2016, 2600Hz
%%% @doc
%%%
%%% @end
%%% @contributors
%%%     SIPLABS, LLC (Ilya Ashchepkov)
%%%-------------------------------------------------------------------
-module(ananke_vm_callback).

-export([init/0
        ,handle_req/2
        ,check/2
        ,has_unread/2
        ]).

-include("ananke.hrl").

-record(args, {account_id             :: api_binary()
              ,user_id               :: api_binary()
              ,vm_box_id             :: api_binary()
              ,callback_number       :: api_binary()
              ,is_callback_disabled  :: boolean()
              ,vm_number             :: api_binary()
              ,schedule              :: pos_integers()
              ,call_timeout          :: pos_integer()
              ,realm                 :: api_binary()
              }).

-spec init() -> 'ok'.
init() ->
    lager:debug("starting supervisor"),
    {'ok', _} = ananke_sup:start_supervisor('ananke_callback_sup'),
    'ok'.

-spec check(ne_binary(), ne_binary()) -> any().
check(AccountId, VMBoxId) ->
    lager:info("checking vmbox ~p in ~p", [VMBoxId, AccountId]),
    case has_unread(AccountId, VMBoxId) of
        'false' ->
            lager:info("no unread messages");
        'true' ->
            lager:info("found unread messages"),
            AccountDb = kz_util:format_account_id(AccountId, 'encoded'),
            handle_req(kz_json:from_list([{<<"Account-ID">>, AccountId}
                                         ,{<<"Account-DB">>, AccountDb}
                                         ,{<<"Voicemail-Box">>, VMBoxId}
                                         ]),
                       [{<<"skip_verification">>, 'true'}])
    end.

has_unread(AccountId, VMBoxId) ->
    {New, _} = kz_vm_message:count_per_folder(AccountId, VMBoxId),
    New > 0.

-spec handle_req(kz_json:object(), kz_proplist()) -> any().
handle_req(JObj, Props) ->
    'true' = props:get_value(<<"skip_verification">>, Props, 'false')
        orelse kapi_notifications:voicemail_saved_v(JObj),
    _ = kz_util:put_callid(JObj),
    AccountId = kz_json:get_value(<<"Account-ID">>, JObj),
    AccountDb = kz_json:get_value(<<"Account-DB">>, JObj),
    VMBoxId = kz_json:get_value(<<"Voicemail-Box">>, JObj),
    lager:debug("handling new voicemail in ~p", [VMBoxId]),
    {'ok', VMBoxJObj} = kz_datamgr:open_cache_doc(AccountDb, VMBoxId),
    case kzd_voicemail_box:owner_id(VMBoxJObj) of
        'undefined' ->
            lager:debug("no owner");
        UserId ->
            lager:debug("voicemail owner is ~p", [UserId]),
            {'ok', UserJObj} = kz_datamgr:open_cache_doc(AccountDb, UserId),
            {'ok', AccountJObj} = kz_datamgr:open_cache_doc(?KZ_ACCOUNTS_DB, AccountId),

            OptionsPath = [<<"notify">>, <<"callback">>],
            VMBoxNotifyJObj = kz_json:get_value(OptionsPath, VMBoxJObj),
            UserNotifyJObj = kz_json:get_value([<<"voicemail">> | OptionsPath], UserJObj),
            AccountNotifyJObj = kz_json:get_value([<<"voicemail">> | OptionsPath], AccountJObj),

            Realm = kz_json:get_value(<<"To-Realm">>, JObj),

            Mailbox = kz_json:get_value(<<"mailbox">>, VMBoxJObj),
            VMNumber = get_voicemail_number(AccountDb, Mailbox),
            Number = get_first_defined([{<<"number">>, VMBoxNotifyJObj}
                                       ,{<<"number">>, UserNotifyJObj}]),
            IsDisabled = kz_util:is_true(
                           get_first_defined([{<<"disabled">>, VMBoxNotifyJObj}
                                             ,{<<"disabled">>, UserNotifyJObj}])),

            Schedule = get_schedule(VMBoxNotifyJObj, UserNotifyJObj, AccountNotifyJObj),
            CallTimeout = get_callback_timeout(VMBoxNotifyJObj, UserNotifyJObj, AccountNotifyJObj),

            StartArgs = #args{account_id = AccountId
                             ,user_id = UserId
                             ,vm_box_id = VMBoxId
                             ,callback_number = Number
                             ,is_callback_disabled = IsDisabled
                             ,vm_number = VMNumber
                             ,schedule = Schedule
                             ,call_timeout = CallTimeout
                             ,realm = Realm
                             },
            maybe_start_caller(StartArgs)
    end.

-spec get_voicemail_number(ne_binary(), ne_binary()) -> api_binary().
get_voicemail_number(AccountDb, Mailbox) ->
    {'ok', Callflows} = kz_datamgr:get_results(AccountDb
                                              ,<<"callflows/crossbar_listing">>
                                              ,[{<<"include_docs">>, 'true'}]),
    case [Cf || Cf <- Callflows, is_voicemail_cf(Cf)] of
        [VMCallflow | _] ->
            get_callflow_number(VMCallflow, Mailbox);
        [] ->
            'undefined'
    end.

-spec is_voicemail_cf(kz_json:object()) -> boolean().
is_voicemail_cf(JObj) ->
    FlowJObj = get_cf_flow(JObj),
    IsFlow = kz_json:is_json_object(FlowJObj)
        andalso not kz_json:is_empty(FlowJObj),
    case {IsFlow
         ,IsFlow
          andalso kz_json:get_value(<<"module">>, FlowJObj) =:= <<"voicemail">>
              andalso kz_json:get_value([<<"data">>, <<"action">>], FlowJObj) =:= <<"check">>
         }
    of
        {'false', _} -> 'false';
        {'true', 'true'} -> 'true';
        _ -> is_voicemail_cf(FlowJObj)
    end.

-spec get_cf_flow(kz_json:object()) -> api_object().
get_cf_flow(JObj) ->
    case kz_json:get_value([<<"children">>, <<"_">>], JObj) of
        'undefined' ->
            kz_json:get_value([<<"doc">>, <<"flow">>], JObj);
        FlowJObj -> FlowJObj
    end.

-spec get_callflow_number(kz_json:object(), ne_binary()) -> api_binary().
get_callflow_number(Callflow, _Mailbox) ->
    case kz_json:get_value([<<"doc">>, <<"numbers">>], Callflow, ['undefined']) of
        [] -> 'undefined';
        [Number | _] -> Number
    end.

-spec maybe_start_caller(#args{}) -> 'ok'.
maybe_start_caller(#args{callback_number = 'undefined'}) ->
    lager:debug("no callback number");
maybe_start_caller(#args{vm_number = 'undefined', account_id = AccountId}) ->
    lager:info("cannot find voicemail number in account ~p", [AccountId]);
maybe_start_caller(#args{is_callback_disabled = 'true', user_id = UserId}) ->
    lager:debug("disabled for user ~p", [UserId]);
maybe_start_caller(StartArgs) ->
    start_caller(StartArgs).

-spec start_caller(#args{}) -> 'ok'.
start_caller(#args{callback_number = Number
                  ,account_id = AccountId
                  ,vm_box_id = VMBoxId
                  ,schedule = Schedule
                  } = StartArgs) ->
    lager:info("starting caller to number ~p", [Number]),
    OriginateReq = build_originate_req(StartArgs),
    CheckFun = {?MODULE, has_unread, [AccountId, VMBoxId]},
    case ananke_callback_sup:start_child({Number, VMBoxId}, OriginateReq, Schedule, CheckFun) of
        {'ok', _} -> lager:debug("started");
        {'ok', _, _} -> lager:debug("started");
        {'error', {'already_started', _}} -> lager:info("already started");
        {'error', Error} -> lager:warning("error: ~p", [Error])
    end.

-spec build_originate_req(#args{}) -> kz_proplist().
build_originate_req(#args{callback_number = CallbackNumber
                         ,vm_number = VMNumber
                         ,account_id = AccountId
                         ,user_id = UserId
                         ,call_timeout = Timeout
                         ,realm = Realm
                         }) ->

    CustomChannelVars = kz_json:from_list([{<<"Account-ID">>, AccountId}
                                          ,{<<"Owner-ID">>, UserId}
                                          ,{<<"AutoAnswer">>, 'true'}
                                          ,{<<"Authorizing-ID">>, UserId}
                                          ,{<<"Inherit-Codec">>, <<"false">>}
                                          ,{<<"Authorizing-Type">>, <<"user">>}
                                          ,{<<"Realm">>, Realm}
                                          ,{<<"Account-Realm">>, Realm}
                                          ,{<<"From-Realm">>, Realm}
                                          ,{<<"Format-From-URI">>, <<"true">>}
                                          ,{<<"From-URI-Realm">>, Realm}
                                          ]),

    Endpoint = [{<<"Invite-Format">>, <<"loopback">>}
               ,{<<"Route">>, CallbackNumber}
               ,{<<"Custom-Channel-Vars">>, CustomChannelVars}
               ],

    ApplicationName = <<"transfer">>,
    ApplicationData = kz_json:from_list([{<<"Route">>, VMNumber}
                                        ,{<<"Custom-Channel-Vars">>, CustomChannelVars}
                                        ]),

    R=[{<<"Timeout">>, Timeout}
      ,{<<"Application-Name">>, ApplicationName}
      ,{<<"Application-Data">>, ApplicationData}
      ,{<<"Originate-Immediate">>, 'true'}
      ,{<<"Ignore-Early-Media">>, 'true'}
      ,{<<"Endpoints">>, [kz_json:from_list(Endpoint)]}
      ,{<<"Dial-Endpoint-Method">>, <<"single">>}
      ,{<<"Continue-On-Fail">>, 'false'}
      ,{<<"Custom-Channel-Vars">>, CustomChannelVars}
      ,{<<"Export-Custom-Channel-Vars">>, [<<"Account-ID">>, <<"Account-Realm">>
                                          ,<<"Authorizing-ID">>, <<"Authorizing-Type">>
                                          ,<<"Owner-ID">>]}
       | kz_api:default_headers(<<"resource">>, <<"originate_req">>, ?APP_NAME, ?APP_VERSION)
      ],
    props:filter_undefined(R).

-spec get_first_defined([{ne_binary(), kz_json:object()}]) -> api_binary().
get_first_defined(Props) ->
    get_first_defined(Props, 'undefined').

-spec get_first_defined([{ne_binary(), kz_json:object()}], any()) -> binary() | any().
get_first_defined([{Keys, JObj} | Rest], Default) ->
    case kz_json:get_value(Keys, JObj) of
        'undefined' ->
            get_first_defined(Rest, Default);
        Val ->
            Val
    end;
get_first_defined([], Default) ->
    Default.

-spec get_schedule(kz_json:object(), kz_json:object(), kz_json:object()) -> pos_integers().
get_schedule(VMBoxJObj, UserJObj, AccountJObj) ->
    case get_first_defined([{<<"schedule">>, VMBoxJObj}
                           ,{<<"schedule">>, UserJObj}
                           ,{<<"schedule">>, AccountJObj}
                           ],
                           [])
    of
        [] ->
            Attempts = get_attempts(VMBoxJObj, UserJObj, AccountJObj),
            Interval = get_interval(VMBoxJObj, UserJObj, AccountJObj),
            get_schedule_from_attempts_interval(Attempts, Interval);
        [_ | _] = Schedule ->
            Schedule
    end.

-spec get_schedule_from_attempts_interval(integer(), pos_integer()) -> pos_integers().
get_schedule_from_attempts_interval(Attempts, Interval) when is_integer(Attempts), is_integer(Interval), Interval > 0 ->
    lists:duplicate(Attempts, Interval);
get_schedule_from_attempts_interval(_Attempts, _Interval) ->
    [].

-spec get_interval(kz_json:object(), kz_json:object(), kz_json:object()) -> integer().
get_interval(VMBoxJObj, UserJObj, AccountJObj) ->
    DefaultInterval = kapps_config:get_binary(?CONFIG_CAT
                                             ,[<<"voicemail">>, <<"notify">>, <<"callback">>, <<"interval_s">>]
                                             ,5*60),
    kz_util:to_integer(
      get_first_defined([{<<"interval_s">>, VMBoxJObj}
                        ,{<<"interval_s">>, UserJObj}
                        ,{<<"interval_s">>, AccountJObj}
                        ]
                       ,DefaultInterval)).

-spec get_attempts(kz_json:object(), kz_json:object(), kz_json:object()) -> integer().
get_attempts(VMBoxJObj, UserJObj, AccountJObj) ->
    DefaultTries = kapps_config:get_binary(?CONFIG_CAT
                                          ,[<<"voicemail">>, <<"notify">>, <<"callback">>, <<"attempts">>]
                                          ,5),
    kz_util:to_integer(
      get_first_defined([{<<"attempts">>, VMBoxJObj}
                        ,{<<"attempts">>, UserJObj}
                        ,{<<"attempts">>, AccountJObj}
                        ]
                       ,DefaultTries)).

-spec get_callback_timeout(kz_json:object(), kz_json:object(), kz_json:object()) -> integer().
get_callback_timeout(VMBoxJObj, UserJObj, AccountJObj) ->
    DefaultCallTimeout = kapps_config:get_binary(?CONFIG_CAT
                                                ,[<<"voicemail">>, <<"notify">>, <<"callback">>, <<"timeout_s">>]
                                                ,20),
    kz_util:to_integer(
      get_first_defined([{<<"timeout_s">>, VMBoxJObj}
                        ,{<<"timeout_s">>, UserJObj}
                        ,{<<"timeout_s">>, AccountJObj}
                        ]
                       ,DefaultCallTimeout)).
