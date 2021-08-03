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
%%% Created : 2021-08-02T07:12:36+00:00
%%%-------------------------------------------------------------------
-module(review_rabbit_plugins).

-author("yangcancai").

-include_lib("stdlib/include/zip.hrl").
-include_lib("kernel/include/file.hrl").

-export([setup/0, enable/1, disable/1, list_plugins/0]).

-include("review_rabbit.hrl").

-rabbit_boot_step({plugins,
                   [{description, "rabbit plugins"},
                    {mfa, {?MODULE, setup, []}},
                    {requires, [pre_boot]}]}).

setup() ->
    EnablePlugins = application:get_env(review_rabbit, enable_plugins, []),
    AllPlugins = list_plugins(),
    Rs = [enable(Plugin) || Plugin <- dependencies(false, EnablePlugins, AllPlugins)],
    ?INFO("Plugins setup ~p", [Rs]),
    ok.

%% 1. 列出系统本身的所有的依赖
%% 2. 列出所有插件
%% 3. 验证插件依赖是否在1和2中
%% 4. 验证插件模块是否可以加载(code:load)
%% 5. 加载整个插件application:load(plugin)
%% 6. 启动插件 application:ensure_all_started(plugin)
enable(Name) ->
    case is_active(Name) of
        false ->
            Loaded = list_loaded(),
            Plugins = list_plugins(),
            #plugin{applications = Deps} = Plugin = lists:keyfind(Name, #plugin.name, Plugins),
            %% 找到没有加载的deps
            {NotThree, Missing} =
                lists:foldl(fun(Dep, {Acc, Miss}) ->
                               case {not lists:member(Dep, Loaded),
                                     not lists:keymember(Dep, #plugin.name, Plugins)}
                               of
                                   {true, true} -> {Acc, [Dep | Miss]};
                                   {false, true} -> {Acc, Miss};
                                   {_, false} -> {[Dep | Acc], Miss}
                               end
                            end,
                            {[], []},
                            Deps),
            case Missing of
                [] ->
                    ok;
                _ ->
                    throw({enable_plugin, Name, missing, Missing})
            end,
            ExpandDir = "expand_plugins",
            %% 解压和加载没有load到runtime的依赖
            [prepare_plugin(DepPlugin, ExpandDir)
             || #plugin{name = DepName} = DepPlugin <- Plugins, lists:member(DepName, NotThree)],
            %% 解压插件
            %% 加载验证插件
            prepare_plugin(Plugin, ExpandDir),
            [begin
                 case application:load(App) of
                     ok ->
                         ok;
                     {error, {already_loaded, App}} ->
                         ok
                 end
             end
             || App <- NotThree ++ [Name]],
            {ok, _} = application:ensure_all_started(Name);
        true ->
            {error, {already_started, Name}}
    end.

disable(Name) ->
    clean_plugin(Name, "expand_plugins").

clean_plugin(Plugin, ExpandDir) ->
    case is_active(Plugin) of
        true ->
            {ok, Mods} = application:get_key(Plugin, modules),
            application:stop(Plugin),
            application:unload(Plugin),
            [begin
                 code:soft_purge(Mod),
                 code:delete(Mod),
                 false = code:is_loaded(Mod)
             end
             || Mod <- Mods],
            delete_plugin(Plugin, ExpandDir);
        _ ->
            ignore
    end.

delete_plugin(Plugin, ExpandDir) ->
    Files =
        [filename:join(ExpandDir, Dir)
         || Dir <- filelib:wildcard(erlang:atom_to_list(Plugin) ++ "*", ExpandDir)],
    delete_file(Files).

delete_file([]) ->
    ok;
delete_file([File | Rest]) ->
    case is_dir(File) of
        true ->
            case prim_file:list_dir(File) of
                {ok, List} ->
                    delete_file([filename:join(File, File1) || File1 <- List]),
                    prim_file:del_dir(File),
                    delete_file(Rest);
                {error, Why} ->
                    error_logger:error_msg("List dir ~p ~p", [File, Why]),
                    delete_file(Rest)
            end;
        false ->
            case prim_file:delete(File) of
                ok ->
                    delete_file(Rest);
                {error, enoent} ->
                    delete_file(Rest);
                {error, Why} ->
                    error_logger:error_msg("Detele file ~p ~p", [File, Why]),
                    delete_file(Rest)
            end
    end.

list_plugins() ->
    list_plugins("plugins").

list_plugins(PluginsDir) ->
    Files = [filename:join(PluginsDir, File) || File <- filelib:wildcard("*.ez", PluginsDir)],
    lists:foldl(fun(F, Acc) ->
                   {ok, [_ | L]} = zip:list_dir(F),
                   case app_deps_info(L, F) of
                       #plugin{} = Plugin -> [Plugin | Acc];
                       _ -> Acc
                   end
                end,
                [],
                Files).

app_deps_info(L, PluginDesc) when is_list(L) ->
    [File] = [F || #zip_file{name = F} <- L, lists:suffix(".app", F)],
    {ok, [{_, B}]} = zip:extract(PluginDesc, [{file_list, [File]}, memory]),
    case parse_binary(B) of
        {application, Name, Props} ->
            app_deps_info(Name, Props, PluginDesc);
        Err ->
            error_logger:error_msg("Plugin app file ~p format ~p", [File, Err]),
            []
    end.

app_deps_info(Name, Props, PluginDesc) ->
    Version = proplists:get_value(vsn, Props, "0"),
    Description = proplists:get_value(description, Props, ""),
    Dependencies = proplists:get_value(applications, Props, []),
    #plugin{name = Name,
            vsn = Version,
            desc = Description,
            location = PluginDesc,
            applications = Dependencies,
            extra_applications = [Dep || Dep <- Dependencies, not is_loaded(Dep)]}.

list_active() ->
    application:which_applications().

is_active(Name) ->
    lists:keymember(Name, 1, list_active()).

is_loaded(Name) ->
    lists:member(Name, list_loaded()).

list_loaded() ->
    [A || {A, _, _} <- application:loaded_applications()].

parse_binary(Bin) ->
    try
        {ok, Ts, _} = erl_scan:string(binary_to_list(Bin)),
        {ok, Term} = erl_parse:parse_term(Ts),
        Term
    catch
        Err ->
            {error, {invalid_app, Err}}
    end.

prepare_plugin(#plugin{name = Name, location = Location}, ExpandDir) ->
    case zip:unzip(Location, [{cwd, ExpandDir}]) of
        {ok, Files} ->
            case find_unzipped_app_file(Files) of
                {ok, PluginAppDescPath} ->
                    prepare_dir_plugin(PluginAppDescPath);
                _ ->
                    error_logger:error_msg("Plugin archive '~s' doesn't contain an .app file~n",
                                           [Location]),
                    throw({app_file_missing, Name, Location})
            end;
        {error, Reason} ->
            error_logger:error_msg("Could not unzip plugin archive '~s': ~p~n", [Location, Reason]),
            throw({failed_to_unzip_plugin, Name, Location, Reason})
    end.

find_unzipped_app_file([]) ->
    {error, unknown_app_file};
find_unzipped_app_file([File | Files]) ->
    [Name, Type | _] =
        lists:reverse(
            filename:split(File)),
    case Type == "ebin" andalso lists:suffix(".app", Name) of
        true ->
            {ok, File};
        _ ->
            find_unzipped_app_file(Files)
    end.

%% 验证插件是否可以load进运行时
prepare_dir_plugin(PluginAppDescPath) ->
    PluginEbinDir = filename:dirname(PluginAppDescPath),
    Plugin = filename:basename(PluginAppDescPath, ".app"),
    code:add_patha(PluginEbinDir),
    case filelib:wildcard(PluginEbinDir ++ "/*.beam") of
        [] ->
            ok;
        [BeamPath | _] ->
            Module = list_to_atom(filename:basename(BeamPath, ".beam")),
            case code:ensure_loaded(Module) of
                {module, _} ->
                    ok;
                {error, badfile} ->
                    error_logger:error_msg("Failed to enable plugin \"~s\": it may have been built with "
                                           "an incompatible (more recent?) version of Erlang~n",
                                           [Plugin]),
                    throw({plugin_built_with_incompatible_erlang, Plugin});
                Error ->
                    throw({plugin_module_unloadable, Plugin, Error})
            end
    end.

is_dir(File) ->
    case prim_file:read_file_info(File) of
        {ok, #file_info{type = directory}} ->
            true;
        _ ->
            false
    end.

dependencies(Reverse, Sources, AllPlugins) ->
    {ok, G} =
        review_rabbit_boot_step:build_acyclic_graph(fun({App, _Deps}) -> [{App, App}] end,
                                                    fun({App, Deps}) -> [{App, Dep} || Dep <- Deps]
                                                    end,
                                                    [{Name, Deps}
                                                     || #plugin{name = Name,
                                                                extra_applications = Deps}
                                                            <- AllPlugins]),
    Dests =
        case Reverse of
            false ->
                digraph_utils:reachable(Sources, G);
            true ->
                digraph_utils:reaching(Sources, G)
        end,
    OrderedDests =
        digraph_utils:postorder(
            digraph_utils:subgraph(G, Dests)),
    true = digraph:delete(G),
    OrderedDests.
