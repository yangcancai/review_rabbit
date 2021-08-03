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
%%% Created : 2021-07-13T09:03:14+00:00
%%%-------------------------------------------------------------------
-module(review_rabbit_boot_step).

-author("yangcancai").

-rabbit_boot_step({pre_boot, [{description, "Pre boot"}]}).
-rabbit_boot_step({first,
                   [{description, "Step First"},
                    {mfa, {io, format, ["Step. First~n"]}},
                    {requires, [pre_boot]},
                    {enables, second}]}).
-rabbit_boot_step({second,
                   [{description, "Step Second"},
                    {mfa, {io, format, ["Step. Second~n"]}},
                    {requires, [first]}]}).

-export([run_boot_steps/0, run_boot_steps/1, run_cleanup_steps/1]).
-export([find_steps/0, find_steps/1, build_acyclic_graph/3]).

-include("review_rabbit.hrl").

run_boot_steps() ->
    run_boot_steps(loaded_applications()).

run_boot_steps(Apps) ->
    [begin
         ?INFO("Running boot step ~s defined by app ~s", [Step, App]),
         ok = run_step(Attrs, mfa)
     end
     || {App, Step, Attrs} <- find_steps(Apps)],
    ok.

run_cleanup_steps(Apps) ->
    [run_step(Attrs, cleanup) || {_, _, Attrs} <- find_steps(Apps)],
    ok.

loaded_applications() ->
    [App || {App, _, _} <- application:loaded_applications()].

find_steps() ->
    find_steps(loaded_applications()).

find_steps(Apps) ->
    All = sort_boot_steps(all_module_attributes(rabbit_boot_step)),
    [Step || {App, _, _} = Step <- All, lists:member(App, Apps)].

run_step(Attributes, AttributeName) ->
    [begin
         ?INFO("Applying MFA: M = ~s, F = ~s, A = ~p", [M, F, A]),
         case apply(M, F, A) of
             ok ->
                 ok;
             {error, Reason} ->
                 exit({error, Reason})
         end
     end
     || {Key, {M, F, A}} <- Attributes, Key =:= AttributeName],
    ok.

all_module_attributes(Name) ->
    Apps = [App || {App, _, _} <- application:loaded_applications()],
    module_attributes_from_apps(Name, Apps).

module_attributes_from_apps(Name, Apps) ->
    Targets =
        lists:usort(
            lists:append([[{App, Module} || Module <- Modules]
                          || App <- Apps, {ok, Modules} <- [application:get_key(App, modules)]])),
    lists:foldl(fun({App, Module}, Acc) ->
                   case lists:append([Atts || {N, Atts} <- module_attributes(Module), N =:= Name])
                   of
                       [] -> Acc;
                       Atts -> [{App, Module, Atts} | Acc]
                   end
                end,
                [],
                Targets).

module_attributes(Module) ->
    try
        Module:module_info(attributes)
    catch
        _:undef ->
            io:format("WARNING: module ~p not found, so not scanned for boot steps.~n", [Module]),
            []
    end.

sort_boot_steps(UnsortedSteps) ->
    case build_acyclic_graph(fun vertices/1, fun edges/1, UnsortedSteps) of
        {ok, G} ->
            %% Use topological sort to find a consistent ordering (if
            %% there is one, otherwise fail).
            SortedSteps =
                lists:reverse([begin
                                   {StepName, Step} = digraph:vertex(G, StepName),
                                   Step
                               end
                               || StepName <- digraph_utils:topsort(G)]),
            digraph:delete(G),
            %% Check that all mentioned {M,F,A} triples are exported.
            case [{StepName, {M, F, A}}
                  || {_App, StepName, Attributes} <- SortedSteps,
                     {mfa, {M, F, A}} <- Attributes,
                     code:ensure_loaded(M) =/= {module, M} orelse
                         not erlang:function_exported(M, F, length(A))]
            of
                [] ->
                    SortedSteps;
                MissingFns ->
                    exit({boot_functions_not_exported, MissingFns})
            end;
        {error, {vertex, duplicate, StepName}} ->
            exit({duplicate_boot_step, StepName});
        {error, {edge, Reason, From, To}} ->
            exit({invalid_boot_step_dependency, From, To, Reason})
    end.

vertices({AppName, _Module, Steps}) ->
    [{StepName, {AppName, StepName, Atts}} || {StepName, Atts} <- Steps].

edges({_AppName, _Module, Steps}) ->
    EnsureList =
        fun (L) when is_list(L) ->
                L;
            (T) ->
                [T]
        end,
    [case Key of
         requires ->
             {StepName, OtherStep};
         enables ->
             {OtherStep, StepName}
     end
     || {StepName, Atts} <- Steps,
        {Key, OtherStepOrSteps} <- Atts,
        OtherStep <- EnsureList(OtherStepOrSteps),
        Key =:= requires orelse Key =:= enables].

build_acyclic_graph(VertexFun, EdgeFun, Graph) ->
    G = digraph:new([acyclic]),
    try
        _ = [case digraph:vertex(G, Vertex) of
                 false ->
                     digraph:add_vertex(G, Vertex, Label);
                 _ ->
                     ok = throw({graph_error, {vertex, duplicate, Vertex}})
             end
             || GraphElem <- Graph, {Vertex, Label} <- VertexFun(GraphElem)],
        [case digraph:add_edge(G, From, To) of
             {error, E} ->
                 throw({graph_error, {edge, E, From, To}});
             _ ->
                 ok
         end
         || GraphElem <- Graph, {From, To} <- EdgeFun(GraphElem)],
        {ok, G}
    catch
        {graph_error, Reason} ->
            true = digraph:delete(G),
            {error, Reason}
    end.
