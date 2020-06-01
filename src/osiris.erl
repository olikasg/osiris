-module(osiris).

-export([
         write/3,
         init_reader/2,
         register_offset_listener/2,
         register_offset_listener/3,
         start_cluster/1,
         stop_cluster/1,
         start_writer/1,
         start_replica/2,
         delete_cluster/1,
         configure_logger/1
         ]).

%% holds static or rarely changing fields
-record(cfg, {}).

-record(?MODULE, {cfg :: #cfg{}}).

-type config() :: #{name := string(),
                    reference => term(),
                    event_formatter => {module(), atom(), list()},
                    retention => [osiris:retention_spec()],
                    atom() => term()}.
-opaque state() :: #?MODULE{}.
-type mfarg() :: {module(), atom(), list()}.

-type offset() :: non_neg_integer().
-type epoch() :: non_neg_integer().
-type milliseconds() :: non_neg_integer().
-type tail_info() :: {offset(), empty | {epoch(), offset()}}.
-type offset_spec() :: first |
                       last |
                       next |
                       {abs, offset()} |
                       offset() |
                       {timestamp, milliseconds()}.

-type retention_spec() :: {max_bytes, non_neg_integer()} |
                          {max_age, milliseconds()}.

-export_type([
              state/0,
              config/0,
              offset/0,
              epoch/0,
              tail_info/0,
              offset_spec/0,
              retention_spec/0
              ]).

-spec start_cluster(config()) ->
    {ok, config()} | {error, term()} | {error, term(), config()}.
start_cluster(Config00 = #{name := Name}) ->
    true = osiris_util:validate_base64uri(Name),
    Config0 = Config00#{external_ref => maps:get(reference, Config00, Name)},
    case osiris_writer:start(Config0) of
        {ok, Pid} ->
            Config = Config0#{leader_pid => Pid},
            case start_replicas(Config) of
                {ok, ReplicaPids} ->
                    {ok, Config#{replica_pids => ReplicaPids}}
                % {error, Reason, ReplicaPids} ->
                %     %% Let the user decide what to do if cluster is only partially started
                %     {error, Reason, Config#{replica_pids => ReplicaPids}}
            end;
        Error ->
            Error
    end.

stop_cluster(Config) ->
    ok = osiris_writer:stop(Config),
    [ok = osiris_replica:stop(N, Config)
     || N <- maps:get(replica_nodes, Config)],
    ok.

-spec delete_cluster(config()) -> ok.
delete_cluster(Config) ->
    [ok = osiris_replica:delete(R, Config)
     || R <- maps:get(replica_nodes, Config)],
    ok = osiris_writer:delete(Config).

start_writer(Config) ->
    osiris_writer:start(Config).

start_replica(Replica, Config) ->
    osiris_replica:start(Replica, Config).

write(Pid, Corr, Data) ->
    osiris_writer:write(Pid, self(), Corr, Data).

%% @doc Initialise a new offset reader
%% @param Pid the pid of a writer or replica process
%% @param OffsetSpec specifies where in the log to attach the reader
%% `first': Attach at first available offset.
%% `last': Attach at the last available chunk offset or the next available offset
%% if the log is empty.
%% `next': Attach to the next chunk offset to be written.
%% `{abs, offset()}': Attach at the provided offset. If this offset does not exist
%% in the log it will error with `{error, {offset_out_of_range, Range}}'
%% `offset()': Like `{abs, offset()}' but instead of erroring it will fall back
%% to `first' (if lower than first offset in log) or `nextl if higher than
%% last offset in log.
%% @returns `{ok, state()} | {error, Error}' when error can be
%% `{offset_out_of_range, empty | {From :: offset(), To :: offset()}}'
%% @end
-spec init_reader(pid(), offset_spec()) ->
    {ok, osiris_log:state()} |
    {error, {offset_out_of_range, empty | {offset(), offset()}}} |
    {error, {invalid_last_offset_epoch, offset(), offset()}}.
init_reader(Pid, OffsetSpec)
  when is_pid(Pid) andalso
       node(Pid) =:= node() ->
    {ok, Ctx} = gen:call(Pid, '$gen_call', get_reader_context),
    osiris_log:init_offset_reader(OffsetSpec, Ctx).

-spec register_offset_listener(pid(), offset()) -> ok.
register_offset_listener(Pid, Offset) ->
    register_offset_listener(Pid, Offset, undefined).

%% @doc
%% Registers a one-off offset listener that will send an `{osiris_offset, offset()}'
%% message when the osiris cluster committed offset moves beyond the provided offset
%% @end
-spec register_offset_listener(pid(), offset(), mfarg() | undefined) -> ok.
register_offset_listener(Pid, Offset, EvtFormatter) ->
    Msg = {'$gen_cast', {register_offset_listener, self(),
                         EvtFormatter, Offset}},
    try erlang:send(Pid, Msg)
    catch
        error:_ -> ok
    end,
    ok.

start_replicas(Config) ->
    start_replicas(Config, maps:get(replica_nodes, Config), []).

start_replicas(_Config, [], ReplicaPids) ->
    {ok, ReplicaPids};
start_replicas(Config, [Node | Nodes], ReplicaPids) ->
    try
        case osiris_replica:start(Node, Config) of
            {ok, Pid} ->
                start_replicas(Config, Nodes, [Pid | ReplicaPids]);
            {ok, Pid, _} ->
                start_replicas(Config, Nodes, [Pid | ReplicaPids]);
            {error, Reason} ->
                error_logger:info_msg("osiris:start_replicas failed to start"
                                      " replica on ~w, reason: ~w",
                                      [Node, Reason]),
                %% coordinator might try to start this replica in the future
                start_replicas(Config, Nodes, ReplicaPids)
        end
    catch
        _:_ ->
            %% coordinator might try to start this replica in the future
            start_replicas(Config, Nodes, ReplicaPids)
    end.

-spec configure_logger(module()) -> ok.
configure_logger(Module) ->
    persistent_term:put('$osiris_logger', Module).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
