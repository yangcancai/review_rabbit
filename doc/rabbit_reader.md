# rabbit_reader

* socket消息入口进程,每个connection一个reader
* 主循环在mainloop,接收消息在rabbit_net:recv函数的receive


##  1. blocking

init的时候把进程注册了` Alarms = rabbit_alarm:register(self(), {?MODULE, conserve_resources, []})`,
所以当资源预警的时候会发送消息给reader进程出发blocking.

## 2. blocked

当reader是blocking的时候，接收到新的消息会触发blocked并且根据capabilities是否开启`connection.blocked`协议,
会给client发送connection.blocked通知的协议,所以client端要处理该协议关闭publisher。消费者的connection和发送者的connection要分开

