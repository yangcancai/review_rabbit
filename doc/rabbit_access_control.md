# Rabbit Access Control

* loopback_users配置

## 1. loopback_users

正常情况guest账号是不允许远程访问的，pro是需要把guest添加到loopback_users列表里面
这样guest账号只能本定访问，如果需要远程访问可以新建新的账号存放到loopback_users列表就好了
`rabbitmqctl status` 可以查看配置文件,配置如下：
```erlang
[
  {rabbit, [

      {loopback_users, []},
      {log, [{file, [{level, debug}]},
             {console, [{level, debug}]}]}
    ]}
].
```
具体代码如下：
```erlang
%% rabbit_access_control.erl
check_user_loopback(Username, SockOrAddr) ->
    {ok, Users} = application:get_env(rabbit, loopback_users),
    case rabbit_net:is_loopback(SockOrAddr)
        orelse not lists:member(Username, Users) of
        true  -> ok;
        false -> not_allowed
    end.
%% 
%% rabbit_web_stomp 插件的rabbit_stomp_processor.erl
start_connection(Params, Username, Addr) ->
    case amqp_connection:start(Params) of
        {ok, Conn} -> case rabbit_access_control:check_user_loopback(
                             Username, Addr) of
                          ok          -> {ok, Conn};
                          not_allowed -> amqp_connection:close(Conn),
                                         {error, not_loopback}
                      end;
        {error, E} -> {error, E}
    end.
```