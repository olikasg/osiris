-module(osiris_SUITE).

-compile(export_all).

-export([
         ]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Common Test callbacks
%%%===================================================================

all() ->
    [
     {group, tests}
    ].


all_tests() ->
    [
     single_node_write,
     cluster_write,
     read_validate
    ].

groups() ->
    [
     {tests, [], all_tests()}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(TestCase, Config) ->
    PrivDir = ?config(priv_dir, Config),
    Dir = filename:join(PrivDir, TestCase),
    application:load(osiris),
    application:set_env(osiris, data_dir, Dir),
    Apps = application:ensure_all_started(osiris),
    [{data_dir, Dir},
     {cluster_name, TestCase},
     {started_apps, Apps} | Config].

end_per_testcase(_TestCase, Config) ->
    [application:stop(App) || App <- lists:reverse(?config(started_apps, Config))],
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================

single_node_write(Config) ->
    _PrivDir = ?config(priv_dir, Config),
    Name = atom_to_list(?FUNCTION_NAME),
    {ok, Leader, _Replicas} = osiris:start_cluster(Name, []),
    ok = osiris:write(Leader, 42, <<"mah-data">>),
    receive
        {osiris_written, _Name, [42]} ->
            ok
    after 2000 ->
              flush(),
              exit(osiris_written_timeout)
    end,
    ok.

cluster_write(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    [LeaderNode | Replicas] = [start_slave(N, PrivDir) || N <- [s1, s2, s3]],
    {ok, Leader, _Replicas} = rpc:call(LeaderNode, osiris, start_cluster,
                                       [atom_to_list(Name), Replicas]),
    ok = osiris:write(Leader, 42, <<"mah-data">>),
    receive
        {osiris_written, _, [42]} ->
            ok
    after 2000 ->
              flush(),
              exit(osiris_written_timeout)
    end,
    Self = self(),
    _ = spawn(LeaderNode,
              fun () ->
                      Seg0 = osiris_writer:init_reader(Leader, 0),
                      {[{0, <<"mah-data">>}], _Seg} = osiris_segment:read_chunk_parsed(Seg0),
                      Self ! read_data_ok
              end),
    receive
        read_data_ok -> ok
    after 2000 ->
              exit(read_data_ok_timeout)
    end,
    ok.


read_validate(Config) ->
    PrivDir = ?config(priv_dir, Config),
    Name = atom_to_list(?FUNCTION_NAME),
    Num = 100000,
    [LeaderNode | Replicas] = [start_slave(N, PrivDir) || N <- [s1, s2, s3]],
    {ok, Leader, _Replicas} = rpc:call(LeaderNode, osiris, start_cluster,
                                       [Name, Replicas]),
     timer:sleep(500),
    % {ok, Leader, _Replicas} = osiris:start_cluster(Name, [],
    %                                                #{max_segment_size => 320000}),
    {Time, _} = timer:tc(fun () -> write_n(Leader, Num, #{}) end),
    ct:pal("~b writes took ~wms", [Num, Time div 1000]),

    ok.

%% Utility

write_n(_Pid, 0, Written) ->
    %% wait for all written events;
    wait_for_written(Written),
    ok;
write_n(Pid, N, Written) ->
    ok = osiris:write(Pid, N, <<N:64/integer>>),
    write_n(Pid, N - 1, Written#{N => ok}).

wait_for_written(Written0) ->
    receive
        {osiris_written, _Name, Corrs} ->
            Written = maps:without(Corrs, Written0),
            case maps:size(Written) of
                0 ->
                    ok;
                _ ->
                    wait_for_written(Written)
            end
    after 2000 ->
              flush(),
              exit(osiris_written_timeout)
    end.

start_slave(N, PrivDir) ->
    Dir0 = filename:join(PrivDir, N),
    Host = get_current_host(),
    Dir = "'\"" ++ Dir0 ++ "\"'",
    Pa = string:join(["-pa" | search_paths()] ++ ["-osiris data_dir", Dir], " "),
    ct:pal("starting slave node with ~s~n", [Pa]),
    {ok, S} = slave:start_link(Host, N, Pa),
    ct:pal("started slave node ~w ~w~n", [S, Host]),
    Res = rpc:call(S, application, ensure_all_started, [osiris]),
    ct:pal("application start result ~p", [Res]),
    S.

flush() ->
    receive
        Any ->
            ct:pal("flush ~p", [Any]),
            flush()
    after 0 ->
              ok
    end.

get_current_host() ->
    {ok, H} = inet:gethostname(),
    list_to_atom(H).

make_node_name(N) ->
    {ok, H} = inet:gethostname(),
    list_to_atom(lists:flatten(io_lib:format("~s@~s", [N, H]))).

search_paths() ->
    Ld = code:lib_dir(),
    lists:filter(fun (P) -> string:prefix(P, Ld) =:= nomatch end,
                 code:get_path()).

