-module(review_rabbit_test).

-include_lib("eunit/include/eunit.hrl").

succeed() ->
    ok.

succeeding_test() ->
    succeed().

succeeding_fun_test_() ->
    fun() -> succeed() end.

succeeding_simple_test_() ->
    ?_test(succeed()).
