%%--------------------------------------------------------------------
%% Copyright (c) 2018-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_listeners_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

all() -> emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    NewConfig = generate_config(),
    application:ensure_all_started(esockd),
    application:ensure_all_started(quicer),
    application:ensure_all_started(cowboy),
    lists:foreach(fun set_app_env/1, NewConfig),
    Config.

end_per_suite(_Config) ->
    application:stop(esockd),
    application:stop(cowboy).

init_per_testcase(Case, Config)
  when Case =:= t_max_conns_tcp; Case =:= t_current_conns_tcp ->
    {ok, _} = emqx_config_handler:start_link(),
    PrevListeners = emqx_config:get([listeners, tcp], #{}),
    PrevRateLimit = emqx_config:get([rate_limit], #{}),
    emqx_config:put([listeners, tcp], #{ listener_test =>
                                             #{ bind => {"127.0.0.1", 9999}
                                              , max_connections => 4321
                                              , limiter => #{}
                                              }
                                  }),
    emqx_config:put([rate_limit], #{max_conn_rate => 1000}),
    ListenerConf = #{ bind => {"127.0.0.1", 9999}
                    },
    ok = emqx_listeners:start(),
    [ {listener_conf, ListenerConf}
    , {prev_listener_conf, PrevListeners}
    , {prev_rate_limit_conf, PrevRateLimit}
    | Config];
init_per_testcase(_, Config) ->
    {ok, _} = emqx_config_handler:start_link(),
    Config.

end_per_testcase(Case, Config)
  when Case =:= t_max_conns_tcp; Case =:= t_current_conns_tcp ->
    PrevListener = ?config(prev_listener_conf, Config),
    PrevRateLimit = ?config(prev_rate_limit_conf, Config),
    emqx_config:put([listeners, tcp], PrevListener),
    emqx_config:put([rate_limit], PrevRateLimit),
    emqx_listeners:stop(),
    _ = emqx_config_handler:stop(),
    ok;
end_per_testcase(_, _Config) ->
    _ = emqx_config_handler:stop(),
    ok.

t_start_stop_listeners(_) ->
    ok = emqx_listeners:start(),
    ?assertException(error, _, emqx_listeners:start_listener({ws,{"127.0.0.1", 8083}, []})),
    ok = emqx_listeners:stop().

t_restart_listeners(_) ->
    ok = emqx_listeners:start(),
    ok = emqx_listeners:stop(),
    ok = emqx_listeners:restart(),
    ok = emqx_listeners:stop().

t_max_conns_tcp(_) ->
    %% Note: Using a string representation for the bind address like
    %% "127.0.0.1" does not work
    ?assertEqual(4321, emqx_listeners:max_conns('tcp:listener_test', {{127,0,0,1}, 9999})).

t_current_conns_tcp(_) ->
    ?assertEqual(0, emqx_listeners:current_conns('tcp:listener_test', {{127,0,0,1}, 9999})).

render_config_file() ->
    Path = local_path(["etc", "emqx.conf"]),
    {ok, Temp} = file:read_file(Path),
    Vars0 = mustache_vars(),
    Vars = [{atom_to_list(N), iolist_to_binary(V)} || {N, V} <- Vars0],
    Targ = bbmustache:render(Temp, Vars),
    NewName = Path ++ ".rendered",
    ok = file:write_file(NewName, Targ),
    NewName.

mustache_vars() ->
    [{platform_data_dir, local_path(["data"])},
     {platform_etc_dir,  local_path(["etc"])},
     {platform_log_dir,  local_path(["log"])},
     {platform_plugins_dir,  local_path(["plugins"])}
    ].

generate_config() ->
    ConfFile = render_config_file(),
    {ok, Conf} = hocon:load(ConfFile, #{format => richmap}),
    hocon_schema:generate(emqx_schema, Conf).

set_app_env({App, Lists}) ->
    lists:foreach(fun({authz_file, _Var}) ->
                      application:set_env(App, authz_file, local_path(["etc", "authz.conf"]));
                     ({plugins_loaded_file, _Var}) ->
                      application:set_env(App,
                                          plugins_loaded_file,
                                          local_path(["test", "emqx_SUITE_data","loaded_plugins"]));
                     ({Par, Var}) ->
                      application:set_env(App, Par, Var)
                  end, Lists).

local_path(Components, Module) ->
    filename:join([get_base_dir(Module) | Components]).

local_path(Components) ->
    local_path(Components, ?MODULE).

get_base_dir(Module) ->
    {file, Here} = code:is_loaded(Module),
    filename:dirname(filename:dirname(Here)).

get_base_dir() ->
    get_base_dir(?MODULE).
