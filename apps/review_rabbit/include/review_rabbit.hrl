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
%%% Created : 2021-08-03T07:23:46+00:00
%%%-------------------------------------------------------------------

-author("yangcancai").

-ifndef(H_review_rabbit).

-define(H_review_rabbit, true).

-record(plugin,
        {name = undefined :: atom(),
         vsn = <<"0.1.0">> :: binary(),
         desc = <<"">> :: binary(),
         location = <<>> :: binary(),
         applications = [] :: list(), %% 依赖
         extra_applications = [] :: list()}). %% 系统未加载的依赖

-define(INFO(Fmt, Argv), error_logger:info_msg(Fmt, Argv)).

-endif.
