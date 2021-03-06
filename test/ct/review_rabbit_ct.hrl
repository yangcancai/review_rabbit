-ifndef(TRACEINSTALL_CT).

-define(TRACEINSTALL_CT, true).

-include_lib("review_rabbit/include/review_rabbit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(log(F, P),
        ct:print("pid = ~p, mod:~p fun:~p ~s ~p ", [self(), ?MODULE, ?FUNCTION_NAME, F, P])).
-define(log(P), ?log("", P)).
-define(log(), ?log("")).

-compile(export_all).

-endif.
