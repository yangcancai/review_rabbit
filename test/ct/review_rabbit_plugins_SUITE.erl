%%%-------------------------------------------------------------------
%%% @author yangcancai

%%% Copyright (c) 2021 by yangcancai(yangcancai0112@gmail.com), All Rights Reserved.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%       https://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%

%%% @doc
%%%
%%% @end
%%% Created : 2021-08-03T07:19:04+00:00
%%%-------------------------------------------------------------------
-module(review_rabbit_plugins_SUITE).

-author("yangcancai").

-include("review_rabbit_ct.hrl").

-compile(export_all).

-define(APP, review_rabbit).

all() ->
    [dependencies].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(?APP),
    new_meck(),
    Config.

end_per_suite(Config) ->
    del_meck(),
    ok = application:stop(?APP),
    Config.

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_Case, _Config) ->
    ok.

new_meck() ->
    % ok = meck:new(review_rabbit_plugins, [non_strict, no_link]),
    ok.

expect() ->
    % ok = meck:expect(review_rabbit_plugins, test, fun() -> {ok, 1} end).
    ok.

del_meck() ->
    meck:unload().

dependencies(_) ->
    [kernel, xmerl, jiffy] =
        review_rabbit_plugins:dependencies(false,
                                           [jiffy],
                                           [#plugin{name = jiffy,
                                                    extra_applications = [xmerl, kernel]},
                                            #plugin{name = xmerl, extra_applications = [kernel]},
                                            #plugin{name = kernel, extra_applications = []},
                                            #plugin{name = stdlib, extra_applications = [a]},
                                            #plugin{name = a, extra_applications = [b]},
                                            #plugin{name = b, extra_applications = []}]).
