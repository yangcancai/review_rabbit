# Rabbit-delayed-message-exchange

* 延迟消息的exchange
* 发送端如果设置了confirm模式会收到return callback回调提示NO ROUTE 


## 1. 创建exchange

* argv: x-delay-type = direct(最终路由消息的类型)
* exchagne_type: x-delayed-message

## 2. 发送消息

* header: x-delay = 1000 (延迟时间毫秒)
* 没有x-delay 会直接路由到队列 

## 3. 存储数据方式

```
	创建两个mnesia的dis_copies表，分别是索引表和数据表，索引表为ordered_set类型,
数据表为bag类型,表的名字分别是[rabbit_delayed_message,node(),_index],[rabbit_delayed_message,node()],
启动一个gen_server接受所有deliver消息，接收到消息后把消息按"当前时间+delay"作为key存储在index表，deliver消息存在数据表。然后判断当前定时器delay时间
是否大于刚接受的deliver，如果大于那么取消当前定时器，用deliver的delay重新启动一个新的定时器。定时器时间到gen_server接受到deliver处理正常route逻辑
然后把数据从index和数据表删除。根据dirty_first(index)获取最新一条即将到期的消息根据该消息启动新的定时器，循环这一个过程。
```

## 4. 查询mnesia数据

```shell
## 查某一条
$ rabbitmqctl eval 'T = erlang:list_to_atom("rabbit_delayed_message"++ erlang:atom_to_list(node())),mnesia:dirty_read(T,mnesia:dirty_first(T)).'
[{delay_entry,
     {delay_key,1626747972535,
         {exchange,
             {resource,<<"/">>,exchange,<<"delayed">>},
             'x-delayed-message',true,false,false,
             [{<<"x-delayed-type">>,longstr,<<"direct">>}],
             undefined,undefined,undefined,
             {[],[rabbit_event_exchange_decorator]},
             #{user => <<"guest">>}}},
     {delivery,true,true,<11241.2282.0>,
         {basic_message,
             {resource,<<"/">>,exchange,<<"delayed">>},
             [<<"two">>],
             {content,60,
                 {'P_basic',undefined,undefined,
                     [{<<"x-delay">>,longstr,<<"600000">>}],
                     2,undefined,undefined,undefined,undefined,undefined,
                     undefined,undefined,undefined,undefined,undefined},
                 none,none,
                 [<<"yes">>]},
             <<186,11,26,123,5,134,138,51,167,65,191,58,2,91,148,67>>,
             true},
         1,noflow},
     #Ref<11241.2495101038.1406664705.53999>}]
## 查所有的
$ rabbitmqctl eval 'T = erlang:list_to_atom("rabbit_delayed_message"++ erlang:atom_to_list(node())),[mnesia:dirty_read(T,K) || K <- mnesia:dirty_all_keys(T)].'
```