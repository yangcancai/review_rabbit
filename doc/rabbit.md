# rabbit

* rabbit_reader(连接入口和协议解析)
* rabbit_channel(处理收到的消息)
* rabbit_amqueue_process(队列进程处理消息入队和投递消息到消费者)

## 1. rabbit_reader.erl

```erlang
process_frame(Frame, Channel, State) ->
    ChKey = {channel, Channel},
    case (case get(ChKey) of
              undefined -> create_channel(Channel, State);
              Other     -> {ok, Other, State}
          end) of
        {error, Error} ->
            handle_exception(State, Channel, Error);
        {ok, {ChPid, AState}, State1} ->
            case rabbit_command_assembler:process(Frame, AState) of
                {ok, NewAState} ->
                    put(ChKey, {ChPid, NewAState}),
                    post_process_frame(Frame, ChPid, State1);
                {ok, Method, NewAState} ->
                    rabbit_channel:do(ChPid, Method),
                    put(ChKey, {ChPid, NewAState}),
                    post_process_frame(Frame, ChPid, State1);
                {ok, Method, Content, NewAState} ->
                    rabbit_channel:do_flow(ChPid, Method, Content),
                    put(ChKey, {ChPid, NewAState}),
                    post_process_frame(Frame, ChPid, control_throttle(State1));
                {error, Reason} ->
                    handle_exception(State1, Channel, Reason)
            end
    end.
```

## 2. rabbit_channel.erl

### 2.1 Channel接收协议处理入口

```erlang
%% rabbit_channel:do(ChPid, Method),
%% rabbit_channel:do_flow(ChPid, Method, Content),
handle_cast({method, Method, Content, Flow},
            State = #ch{cfg = #conf{reader_pid = Reader},
                        interceptor_state = IState}) ->
    case Flow of
        %% We are going to process a message from the rabbit_reader
        %% process, so here we ack it. In this case we are accessing
        %% the rabbit_channel process dictionary.
        flow   -> credit_flow:ack(Reader);
        noflow -> ok
    end,
    try handle_method(rabbit_channel_interceptor:intercept_in(
                        expand_shortcuts(Method, State), Content, IState),
                      State) of
        {reply, Reply, NewState} ->
            ok = send(Reply, NewState),
            noreply(NewState);
        {noreply, NewState} ->
            noreply(NewState);
        stop ->
            {stop, normal, State}
    catch
        exit:Reason = #amqp_error{} ->
            MethodName = rabbit_misc:method_record_type(Method),
            handle_exception(Reason#amqp_error{method = MethodName}, State);
        _:Reason:Stacktrace ->
            {stop, {Reason, Stacktrace}, State}
    end.

%% 消息接收入口
handle_method(#'basic.publish'{exchange    = ExchangeNameBin,
                               routing_key = RoutingKey,
                               mandatory   = Mandatory},
              Content, State = #ch{cfg = #conf{channel = ChannelNum,
                                               conn_name = ConnName,
                                               virtual_host = VHostPath,
                                               user = #user{username = Username} = User,
                                               trace_state = TraceState,
                                               max_message_size = MaxMessageSize,
                                               authz_context = AuthzContext,
                                               writer_gc_threshold = GCThreshold
                                              },
                                   tx               = Tx,
                                   confirm_enabled  = ConfirmEnabled,
                                   %% delivery_flow =  rabbit_misc:get_env(rabbit, mirroring_flow_control, true)
                                   delivery_flow    = Flow
                                   }) ->
    check_msg_size(Content, MaxMessageSize, GCThreshold),
    ExchangeName = rabbit_misc:r(VHostPath, exchange, ExchangeNameBin),
    check_write_permitted(ExchangeName, User, AuthzContext),
    Exchange = rabbit_exchange:lookup_or_die(ExchangeName),
    check_internal_exchange(Exchange),
    check_write_permitted_on_topic(Exchange, User, RoutingKey, AuthzContext),
    %% We decode the content's properties here because we're almost
    %% certain to want to look at delivery-mode and priority.
    DecodedContent = #content {properties = Props} =
        maybe_set_fast_reply_to(
          rabbit_binary_parser:ensure_content_decoded(Content), State),
    check_user_id_header(Props, State),
    check_expiration_header(Props),
    DoConfirm = Tx =/= none orelse ConfirmEnabled,
    {MsgSeqNo, State1} =
        case DoConfirm orelse Mandatory of
            false -> {undefined, State};
            true  -> SeqNo = State#ch.publish_seqno,
                     {SeqNo, State#ch{publish_seqno = SeqNo + 1}}
        end,
    case rabbit_basic:message(ExchangeName, RoutingKey, DecodedContent) of
        {ok, Message} ->
            Delivery = rabbit_basic:delivery(
                         Mandatory, DoConfirm, Message, MsgSeqNo),
            %% 根据绑定的key查找对应的queue列表
            %% 自定义的exchange插件实现的route入口就是这里 
            QNames = rabbit_exchange:route(Exchange, Delivery),
            rabbit_trace:tap_in(Message, QNames, ConnName, ChannelNum,
                                Username, TraceState),
            DQ = {Delivery#delivery{flow = Flow}, QNames},
            {noreply, case Tx of
                          none         -> deliver_to_queues(DQ, State1);
                          {Msgs, Acks} -> Msgs1 = ?QUEUE:in(DQ, Msgs),
                                          State1#ch{tx = {Msgs1, Acks}}
                      end};
        {error, Reason} ->
            precondition_failed("invalid message: ~p", [Reason])
    end;
%% 发送消息到队列
%% 如果没有绑定队列且mandatory=false，confirm=false，不做处理
deliver_to_queues({#delivery{message   = #basic_message{exchange_name = XName},
                             confirm   = false,
                             mandatory = false},
                   _RoutedToQs = []}, State) -> %% optimisation
    ?INCR_STATS(exchange_stats, XName, 1, publish, State),
    ?INCR_STATS(exchange_stats, XName, 1, drop_unroutable, State),
    State;
deliver_to_queues({Delivery = #delivery{message    = Message = #basic_message{
                                                       exchange_name = XName},
                                        mandatory  = Mandatory,
                                        confirm    = Confirm,
                                        msg_seq_no = MsgSeqNo},
                   DelQNames}, State = #ch{queue_names    = QNames,
                                           queue_monitors = QMons,
                                           queue_states = QueueStates0}) ->
    %% 根据队列名称获取队列pid
    Qs = rabbit_amqqueue:lookup(DelQNames),
    %% 发送消息到队列进程
    {DeliveredQPids, DeliveredQQPids, QueueStates} =
        rabbit_amqqueue:deliver(Qs, Delivery, QueueStates0),
    AllDeliveredQRefs = DeliveredQPids ++ [N || {N, _} <- DeliveredQQPids],
    %% The maybe_monitor_all/2 monitors all queues to which we
    %% delivered. But we want to monitor even queues we didn't deliver
    %% to, since we need their 'DOWN' messages to clean
    %% queue_names. So we also need to monitor each QPid from
    %% queues. But that only gets the masters (which is fine for
    %% cleaning queue_names), so we need the union of both.
    %%
    %% ...and we need to add even non-delivered queues to queue_names
    %% since alternative algorithms to update queue_names less
    %% frequently would in fact be more expensive in the common case.
    {QNames1, QMons1} =
        lists:foldl(fun (Q, {QNames0, QMons0}) when ?is_amqqueue(Q) ->
            QPid = amqqueue:get_pid(Q),
            QRef = qpid_to_ref(QPid),
            QName = amqqueue:get_name(Q),
            case ?IS_CLASSIC(QRef) of
                true ->
                    SPids = amqqueue:get_slave_pids(Q),
                    NewQNames =
                        maps:from_list([{Ref, QName} || Ref <- [QRef | SPids]]),
                    {maps:merge(NewQNames, QNames0),
                     maybe_monitor_all([QPid | SPids], QMons0)};
                false ->
                    {maps:put(QRef, QName, QNames0), QMons0}
            end
        end,
        {QNames, QMons}, Qs),
    State1 = State#ch{queue_names    = QNames1,
                      queue_monitors = QMons1},
    %% NB: the order here is important since basic.returns must be
    %% sent before confirms.
    %% 处理mandatory主要是为了当没有绑定队列的时候返回basic.returns 回调
    ok = process_routing_mandatory(Mandatory, AllDeliveredQRefs,
                                   Message, State1),
    AllDeliveredQNames = [ QName || QRef        <- AllDeliveredQRefs,
                                    {ok, QName} <- [maps:find(QRef, QNames1)]],
    %% 如果有绑定队列，那么把消息id存储到unconfirmed字段，
    %% 否则把消息存储到confirmed字段
    %% 等待接收emit_stats定时器处理发送ack或者nack给client
    State2 = process_routing_confirm(Confirm,
                                     AllDeliveredQRefs,
                                     AllDeliveredQNames,
                                     MsgSeqNo,
                                     XName, State1),
    case rabbit_event:stats_level(State, #ch.stats_timer) of
        fine ->
            ?INCR_STATS(exchange_stats, XName, 1, publish),
            [?INCR_STATS(queue_exchange_stats,
                         {amqqueue:get_name(Q), XName}, 1, publish) ||
                Q        <- Qs];
        _ ->
            ok
    end,
    State2#ch{queue_states = QueueStates}.


%% 当发送消息配置了mandatory=true
%% 如果没有绑定队列会发送basic_return
process_routing_mandatory(_Mandatory = true,
                          _RoutedToQs = [],
                          Msg, State) ->
    ok = basic_return(Msg, State, no_route),
    ok;
%% 如果没有设置那么不对发送basic_return
process_routing_mandatory(_Mandatory = false,
                          _RoutedToQs = [],
                          #basic_message{exchange_name = ExchangeName}, State) ->
    ?INCR_STATS(exchange_stats, ExchangeName, 1, drop_unroutable, State),
    ok;
process_routing_mandatory(_, _, _, _) ->
    ok.

process_routing_confirm(false, _, _, _, _, State) ->
    State;
process_routing_confirm(true, [], _, MsgSeqNo, XName, State) ->
    record_confirms([{MsgSeqNo, XName}], State);
process_routing_confirm(true, QRefs, QNames, MsgSeqNo, XName, State) ->
    State#ch{unconfirmed =
        unconfirmed_messages:insert(MsgSeqNo, QNames, QRefs, XName,
                                    State#ch.unconfirmed)}.

```

### 2.2 RabbitChannel接收到队列进程的Confirm返回

   confirm模式某个消息只有所有队列都返回了confirm才会发送ack给client,
如果发送的消息配置了mandoary=true且routingkey没有绑定队列,
那么会返回一个basic.return消息表明该routingkey为NO_ROUTE,接着channel会发送ack给client

```erlang
%% 接受队列确认返回
handle_cast({confirm, MsgSeqNos, QPid}, State) ->
    noreply_coalesce(confirm(MsgSeqNos, QPid, State));

%% 定时处理confirm
noreply_coalesce(State = #ch{confirmed = C, rejected = R}) ->
    Timeout = case {C, R} of {[], []} -> hibernate; _ -> 0 end,
    {noreply, ensure_stats_timer(State), Timeout}.

ensure_stats_timer(State) ->
    rabbit_event:ensure_stats_timer(State, #ch.stats_timer, emit_stats).


%% 定时处理confirm事件
handle_info(emit_stats, State) ->
    emit_stats(State),
    State1 = rabbit_event:reset_stats_timer(State, #ch.stats_timer),
    %% NB: don't call noreply/1 since we don't want to kick off the
    %% stats timer.
    {noreply, send_confirms_and_nacks(State1), hibernate};

%% 发送confirm到client
send_confirms_and_nacks(State = #ch{tx = none, confirmed = C, rejected = R}) ->
    case rabbit_node_monitor:pause_partition_guard() of
        ok      ->
            Confirms = lists:append(C),
            Rejects = lists:append(R),
            ConfirmMsgSeqNos =
                lists:foldl(
                    fun ({MsgSeqNo, XName}, MSNs) ->
                        ?INCR_STATS(exchange_stats, XName, 1, confirm, State),
                        [MsgSeqNo | MSNs]
                    end, [], Confirms),
            RejectMsgSeqNos = [MsgSeqNo || {MsgSeqNo, _} <- Rejects],

            State1 = send_confirms(ConfirmMsgSeqNos,
                                   RejectMsgSeqNos,
                                   State#ch{confirmed = []}),
            %% TODO: msg seq nos, same as for confirms. Need to implement
            %% nack rates first.
            send_nacks(RejectMsgSeqNos,
                       ConfirmMsgSeqNos,
                       State1#ch{rejected = []});
        pausing -> State
    end;

send_confirms([MsgSeqNo], _, State) ->
    ok = send(#'basic.ack'{delivery_tag = MsgSeqNo}, State),
    State;
send_confirms(Cs, Rs, State) ->
    coalesce_and_send(Cs, Rs,
                      fun(MsgSeqNo, Multiple) ->
                                  #'basic.ack'{delivery_tag = MsgSeqNo,
                                               multiple     = Multiple}
                      end, State).

%% 发送ack或者nack给client
coalesce_and_send(MsgSeqNos, NegativeMsgSeqNos, MkMsgFun, State = #ch{unconfirmed = UC}) ->
    SMsgSeqNos = lists:usort(MsgSeqNos),
    UnconfirmedCutoff = case unconfirmed_messages:is_empty(UC) of
                 true  -> lists:last(SMsgSeqNos) + 1;
                 false -> unconfirmed_messages:smallest(UC)
             end,
    Cutoff = lists:min([UnconfirmedCutoff | NegativeMsgSeqNos]),
    %% 把连续的和不连续的消息分开
    {Ms, Ss} = lists:splitwith(fun(X) -> X < Cutoff end, SMsgSeqNos),
    %% 连续的消息发送最后一条消息给client
    %% 确认的ack
    %% #'basic.ack'{delivery_tag = MsgSeqNo,
    %% multiple表示是否是连续确认的
    %% multiple     = true}
    %% 拒绝的nack
    %% #'basic.nack'{delivery_tag = MsgSeqNo,
    %% multiple表示是否是连续确认的
    %% multiple     = true}

    case Ms of
        [] -> ok;
	%% 发送连续confirm的最大Ms
        _  -> ok = send(MkMsgFun(lists:last(Ms), true), State)
    end,
    %% 不连续的ms单个发送,multiple=false表示每次单条消息确认
    [ok = send(MkMsgFun(SeqNo, false), State) || SeqNo <- Ss],
    State.

%% 发送拒绝的ms
send_nacks(Rs, Cs, State) ->
    coalesce_and_send(Rs, Cs,
                      fun(MsgSeqNo, Multiple) ->
                              #'basic.nack'{delivery_tag = MsgSeqNo,
                                            multiple     = Multiple}
                      end, State).

```

## 3 队列进程(rabbit_amqqueue_process.erl)

### 3.1 接收到channel发送的delivery

```erlang
handle_cast({deliver,
                Delivery = #delivery{sender = Sender,
                                     flow   = Flow},
                SlaveWhenPublished},
            State = #q{senders = Senders}) ->
    Senders1 = case Flow of
    %% In both credit_flow:ack/1 we are acking messages to the channel
    %% process that sent us the message delivery. See handle_ch_down
    %% for more info.
                   flow   -> credit_flow:ack(Sender),
                             case SlaveWhenPublished of
                                 true  -> credit_flow:ack(Sender); %% [0]
                                 false -> ok
                             end,
                             pmon:monitor(Sender, Senders);
                   noflow -> Senders
               end,
    State1 = State#q{senders = Senders1},
    noreply(maybe_deliver_or_enqueue(Delivery, SlaveWhenPublished, State1));
```

### 3.2 处理deliver或者入队

```erlang
maybe_deliver_or_enqueue(Delivery = #delivery{message = Message},
                         Delivered,
                         State = #q{overflow            = Overflow,
                                    backing_queue       = BQ,
                                    backing_queue_state = BQS,
                                    dlx                 = DLX,
                                    dlx_routing_key     = RK}) ->
    send_mandatory(Delivery), %% must do this before confirms
    %% 队列满了的处理方式：drop或者进入死信队列
    case {will_overflow(Delivery, State), Overflow} of
        {true, 'reject-publish'} ->
            %% Drop publish and nack to publisher
            send_reject_publish(Delivery, Delivered, State);
        {true, 'reject-publish-dlx'} ->
            %% Publish to DLX
            with_dlx(
              DLX,
              fun (X) ->
                      QName = qname(State),
                      rabbit_dead_letter:publish(Message, maxlen, X, RK, QName)
              end,
              fun () -> ok end),
            %% Drop publish and nack to publisher
            send_reject_publish(Delivery, Delivered, State);
        _ ->
            {IsDuplicate, BQS1} = BQ:is_duplicate(Message, BQS),
            State1 = State#q{backing_queue_state = BQS1},
            case IsDuplicate of
                true -> State1;
                {true, drop} -> State1;
                %% Drop publish and nack to publisher
                {true, reject} ->
                    send_reject_publish(Delivery, Delivered, State1);
                %% Enqueue and maybe drop head later
                false ->
                    deliver_or_enqueue(Delivery, Delivered, State1)
            end
    end.

deliver_or_enqueue(Delivery = #delivery{message = Message,
                                        sender  = SenderPid,
                                        flow    = Flow},
                   Delivered,
                   State = #q{backing_queue = BQ}) ->
    {Confirm, State1} = send_or_record_confirm(Delivery, State),
    Props = message_properties(Message, Confirm, State1),
    case attempt_delivery(Delivery, Props, Delivered, State1) of
        {delivered, State2} ->
            State2;
        %% The next one is an optimisation
        {undelivered, State2 = #q{ttl = 0, dlx = undefined,
                                  backing_queue_state = BQS,
                                  msg_id_to_channel   = MTC}} ->
            {BQS1, MTC1} = discard(Delivery, BQ, BQS, MTC),
            State2#q{backing_queue_state = BQS1, msg_id_to_channel = MTC1};
        {undelivered, State2 = #q{backing_queue_state = BQS}} ->

            BQS1 = BQ:publish(Message, Props, Delivered, SenderPid, Flow, BQS),
            {Dropped, State3 = #q{backing_queue_state = BQS2}} =
                maybe_drop_head(State2#q{backing_queue_state = BQS1}),
            QLen = BQ:len(BQS2),
            %% optimisation: it would be perfectly safe to always
            %% invoke drop_expired_msgs here, but that is expensive so
            %% we only do that if a new message that might have an
            %% expiry ends up at the head of the queue. If the head
            %% remains unchanged, or if the newly published message
            %% has no expiry and becomes the head of the queue then
            %% the call is unnecessary.
            case {Dropped, QLen =:= 1, Props#message_properties.expiry} of
                {false, false,         _} -> State3;
                {true,  true,  undefined} -> State3;
                {_,     _,             _} -> drop_expired_msgs(State3)
            end
    end.
```