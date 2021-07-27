# rabbit_reader

* socket消息入口进程,每个connection一个reader
* 主循环在mainloop,接收消息在rabbit_net:recv函数的receive


## 1. blocking

init的时候把进程注册了` Alarms = rabbit_alarm:register(self(), {?MODULE, conserve_resources, []})`,
所以当资源预警的时候会发送消息给reader进程触发blocking.

## 2. blocked

当reader是blocking的时候，接收到新的消息会触发blocked并且根据capabilities是否开启`connection.blocked`协议,
会给client发送connection.blocked通知的协议,所以client端要处理该协议关闭publisher。
reader blocked的时候不影响消费者,在blocked的时候reader不再从socket接收数据，因为socket设置了{active，once},
所以每次接收数据都要执行一次{active,once}。当触发blocked的时候recvloop直接绕过了该设置所以reader这个时候只接收除了socket以外的消息

### 2.1 Reader的loop代码

```erlang
%% rabbit_reader.erl
recvloop(Deb, Buf, BufLen, State = #v1{pending_recv = true}) ->
    mainloop(Deb, Buf, BufLen, State);
recvloop(Deb, Buf, BufLen, State = #v1{connection_state = blocked}) ->
     %% blocked了不再接收socket数据
    mainloop(Deb, Buf, BufLen, State);
recvloop(Deb, Buf, BufLen, State = #v1{connection_state = {become, F}}) ->
    throw({become, F(Deb, Buf, BufLen, State)});
recvloop(Deb, Buf, BufLen, State = #v1{sock = Sock, recv_len = RecvLen})
  when BufLen < RecvLen ->
   %% 接收数据之前需要设置一下active,once
   %% socket底层才会把数据发送给reader进程
    case rabbit_net:setopts(Sock, [{active, once}]) of
        ok              -> mainloop(Deb, Buf, BufLen,
                                    State#v1{pending_recv = true});
        {error, Reason} -> stop(Reason, State)
    end;
recvloop(Deb, [B], _BufLen, State) ->
    {Rest, State1} = handle_input(State#v1.callback, B, State),
    recvloop(Deb, [Rest], size(Rest), State1);
recvloop(Deb, Buf, BufLen, State = #v1{recv_len = RecvLen}) ->
    {DataLRev, RestLRev} = binlist_split(BufLen - RecvLen, Buf, []),
    Data = list_to_binary(lists:reverse(DataLRev)),
    {<<>>, State1} = handle_input(State#v1.callback, Data, State),
    recvloop(Deb, lists:reverse(RestLRev), BufLen - RecvLen, State1).

mainloop(Deb, Buf, BufLen, State = #v1{sock = Sock,
                                       connection_state = CS,
                                       connection = #connection{
                                         name = ConnName}}) ->
    %% 接收socket数据或者别的数据
    %% 相当于一个handle_info
    Recv = rabbit_net:recv(Sock),
    case CS of
        pre_init when Buf =:= [] ->
            %% We only log incoming connections when either the
            %% first byte was received or there was an error (eg. a
            %% timeout).
            %%
            %% The goal is to not log TCP healthchecks (a connection
            %% with no data received) unless specified otherwise.
            Fmt = "accepting AMQP connection ~p (~s)~n",
            Args = [self(), ConnName],
            case Recv of
                closed -> rabbit_log_connection:debug(Fmt, Args);
                _      -> rabbit_log_connection:info(Fmt, Args)
            end;
        _ ->
            ok
    end,
    case Recv of
        {data, Data} ->
            recvloop(Deb, [Data | Buf], BufLen + size(Data),
                     State#v1{pending_recv = false});
        closed when State#v1.connection_state =:= closed ->
            State;
        closed when CS =:= pre_init andalso Buf =:= [] ->
            stop(tcp_healthcheck, State);
        closed ->
            stop(closed, State);
        {other, {heartbeat_send_error, Reason}} ->
            %% The only portable way to detect disconnect on blocked
            %% connection is to wait for heartbeat send failure.
            stop(Reason, State);
        {error, Reason} ->
            stop(Reason, State);
        {other, {system, From, Request}} ->
            sys:handle_system_msg(Request, From, State#v1.parent,
                                  ?MODULE, Deb, {Buf, BufLen, State});
        {other, Other}  ->
            case handle_other(Other, State) of
                stop     -> State;
                NewState -> recvloop(Deb, Buf, BufLen, NewState)
            end
    end.
%% rabbit_net.erl
recv(Sock) when ?IS_SSL(Sock) ->
    recv(Sock, {ssl, ssl_closed, ssl_error});
recv(Sock) when is_port(Sock) ->
    recv(Sock, {tcp, tcp_closed, tcp_error}).

recv(S, {DataTag, ClosedTag, ErrorTag}) ->
    receive
        %% 接收socket数据
        {DataTag, S, Data}    -> {data, Data};
	%% socket关闭
        {ClosedTag, S}        -> closed;
	%% tcp_error
        {ErrorTag, S, Reason} -> {error, Reason};
	%% 别的消息
        Other                 -> {other, Other}
    end.

```

### 2.2 Reader解析frame

```eralng
handle_input(frame_header, <<Type:8,Channel:16,PayloadSize:32, _/binary>>,
             State = #v1{connection = #connection{frame_max = FrameMax}})
  when FrameMax /= 0 andalso
       PayloadSize > FrameMax - ?EMPTY_FRAME_SIZE + ?FRAME_SIZE_FUDGE ->
    fatal_frame_error(
      {frame_too_large, PayloadSize, FrameMax - ?EMPTY_FRAME_SIZE},
      Type, Channel, <<>>, State);
handle_input(frame_header, <<Type:8,Channel:16,PayloadSize:32,
                             Payload:PayloadSize/binary, ?FRAME_END,
                             Rest/binary>>,
             State) ->
    {Rest, ensure_stats_timer(handle_frame(Type, Channel, Payload, State))};
handle_input(frame_header, <<Type:8,Channel:16,PayloadSize:32, Rest/binary>>,
             State) ->
    {Rest, ensure_stats_timer(
             switch_callback(State,
                             {frame_payload, Type, Channel, PayloadSize},
                             PayloadSize + 1))};
handle_input({frame_payload, Type, Channel, PayloadSize}, Data, State) ->
    <<Payload:PayloadSize/binary, EndMarker, Rest/binary>> = Data,
    case EndMarker of
        ?FRAME_END -> State1 = handle_frame(Type, Channel, Payload, State),
                      {Rest, switch_callback(State1, frame_header, 7)};
        _          -> fatal_frame_error({invalid_frame_end_marker, EndMarker},
                                        Type, Channel, Payload, State)
    end;
handle_input(handshake, <<"AMQP", A, B, C, D, Rest/binary>>, State) ->
    {Rest, handshake({A, B, C, D}, State)};
handle_input(handshake, <<Other:8/binary, _/binary>>, #v1{sock = Sock}) ->
    refuse_connection(Sock, {bad_header, Other});
handle_input(Callback, Data, _State) ->
    throw({bad_input, Callback, Data}).

    handle_frame(Type, 0, Payload,
             State = #v1{connection = #connection{protocol = Protocol}})
  when ?IS_STOPPING(State) ->
    case rabbit_command_assembler:analyze_frame(Type, Payload, Protocol) of
        {method, MethodName, FieldsBin} ->
            handle_method0(MethodName, FieldsBin, State);
        _Other -> State
    end;
handle_frame(Type, 0, Payload,
             State = #v1{connection = #connection{protocol = Protocol}}) ->
    case rabbit_command_assembler:analyze_frame(Type, Payload, Protocol) of
        error     -> frame_error(unknown_frame, Type, 0, Payload, State);
        heartbeat -> State;
        {method, MethodName, FieldsBin} ->
            handle_method0(MethodName, FieldsBin, State);
        _Other    -> unexpected_frame(Type, 0, Payload, State)
    end;
handle_frame(Type, Channel, Payload,
             State = #v1{connection = #connection{protocol = Protocol}})
  when ?IS_RUNNING(State) ->
    case rabbit_command_assembler:analyze_frame(Type, Payload, Protocol) of
        error     -> frame_error(unknown_frame, Type, Channel, Payload, State);
        heartbeat -> unexpected_frame(Type, Channel, Payload, State);
        Frame     -> process_frame(Frame, Channel, State)
    end;
handle_frame(_Type, _Channel, _Payload, State) when ?IS_STOPPING(State) ->
    State;
handle_frame(Type, Channel, Payload, State) ->
    unexpected_frame(Type, Channel, Payload, State).
```

### 2.3 Reader处理frame

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
		   %% 有内容的协议需要执行流控
                    rabbit_channel:do_flow(ChPid, Method, Content),
                    put(ChKey, {ChPid, NewAState}),
		    %% control_throttle会处理流控
		    %% 会修改reader的状态
                    post_process_frame(Frame, ChPid, control_throttle(State1));
                {error, Reason} ->
                    handle_exception(State1, Channel, Reason)
            end
    end.
```

### 2.4 Reader处理流控

```erlang
control_throttle(State = #v1{connection_state = CS,
                             throttle = #throttle{blocked_by = Reasons} = Throttle}) ->
    %% 发送到channel触发了流控
    Throttle1 = case credit_flow:blocked() of
                  true  ->
                    Throttle#throttle{blocked_by = sets:add_element(flow, Reasons)};
                  false ->
                    Throttle#throttle{blocked_by = sets:del_element(flow, Reasons)}
             end,
    State1 = State#v1{throttle = Throttle1},
    case CS of
    %% reader会被blocked
    %% 所以生产端最好使用多个channel来发送消息
    %% 不同的channel对应不同的queue,提高吞吐量
        running -> maybe_block(State1);
        %% unblock or re-enable blocking
        blocked -> maybe_block(maybe_unblock(State1));
        _       -> State1
    end.
```
### 2.5 发送connect.blocked代码

```erlang
%% rabbit_reader.erl
send_blocked(#v1{connection = #connection{protocol     = Protocol,
                                          capabilities = Capabilities},
                 sock       = Sock}, Reason) ->
    %%  判断是否开启了connection.blocked协议
    case rabbit_misc:table_lookup(Capabilities, <<"connection.blocked">>) of
        {bool, true} ->

            ok = send_on_channel0(Sock, #'connection.blocked'{reason = Reason},
                                  Protocol);
        _ ->
            ok
    end.

send_unblocked(#v1{connection = #connection{protocol     = Protocol,
                                            capabilities = Capabilities},
                   sock       = Sock}) ->
    case rabbit_misc:table_lookup(Capabilities, <<"connection.blocked">>) of
        {bool, true} ->
            ok = send_on_channel0(Sock, #'connection.unblocked'{}, Protocol);
        _ ->
            ok
    end.
```