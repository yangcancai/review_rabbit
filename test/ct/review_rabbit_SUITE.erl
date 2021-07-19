-module(review_rabbit_SUITE).

-include("review_rabbit_ct.hrl").

-compile(export_all).

all() ->
    [handle].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(review_rabbit),
    new_meck(),
    Config.

end_per_suite(Config) ->
    del_meck(),
    application:stop(review_rabbit),
    Config.

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_Case, _Config) ->
    ok.

new_meck() ->
    ok = meck:new(review_rabbit, [non_strict, no_link]),
    ok.

expect() ->
    ok = meck:expect(review_rabbit, test, fun() -> {ok, 1} end).
del_meck() ->
    meck:unload().

handle(_Config) ->
    expect(),
    ?assertEqual({ok,1}, review_rabbit:test()),
    ok.