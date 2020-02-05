%% @hidden
-module(osiris_writer).
-behaviour(gen_batch_server).

-export([start_link/1,
         start/2,
         init_reader/2,
         register_data_listener/2,
         register_offset_listener/1,
         ack/2,
         write/4,
         init/1,
         handle_batch/2,
         terminate/2,
         format_status/1,
         stop/1,
         delete/2
        ]).

%% primary osiris process
%% batch writes incoming data
%% notifies replicator and reader processes of the new max index
%% manages incoming max index

-record(cfg, {name :: string(),
              ext_reference :: term(),
              offset_ref :: atomics:atomics_ref(),
              replicas = [] :: [node()],
              directory :: file:filename(),
              counter :: counters:counters_ref()
             }).

-record(?MODULE, {cfg :: #cfg{},
                  segment = osiris_segment:state(),
                  pending_writes = #{} :: #{osiris_segment:offset() =>
                                            {[node()], #{pid() => [term()]}}},
                  data_listeners = [] :: [{pid(), osiris_segment:offset()}],
                  offset_listeners = [] :: [pid()],
                  committed_offset = -1 :: osiris_segment:offset()
                 }).

-opaque state() :: #?MODULE{}.

-export_type([state/0]).

start(Name, Config0) ->
    Config = Config0#{name => Name},
    supervisor:start_child(osiris_writer_sup,
                           #{id => Name,
                             start => {?MODULE, start_link, [Config]},
                             restart => transient,
                             shutdown => 5000,
                             type => worker}).

stop(Name) ->
    ok = supervisor:terminate_child(osiris_writer_sup, Name),
    ok = supervisor:delete_child(osiris_writer_sup, Name).

delete(Name, Server) ->
    gen_batch_server:call(Server, delete),
    rpc:call(node(Server), ?MODULE, stop, [Name]).

-spec start_link(Config :: map()) ->
    {ok, pid()} | {error, {already_started, pid()}}.
start_link(Config) ->
    gen_batch_server:start_link(?MODULE, Config).

init_reader(Pid, StartOffset) when node(Pid) == node() ->
    Ctx = gen_batch_server:call(Pid, get_reader_context),
    osiris_segment:init_reader(StartOffset, Ctx).

register_data_listener(Pid, Offset) ->
    ok = gen_batch_server:cast(Pid, {register_data_listener, self(), Offset}).

register_offset_listener(Pid) ->
    ok = gen_batch_server:cast(Pid, {register_offset_listener, self()}).

ack(LeaderPid, Offsets) ->
    gen_batch_server:cast(LeaderPid, {ack, node(), Offsets}).

write(Pid, Sender, Corr, Data) ->
    gen_batch_server:cast(Pid, {write, Sender, Corr, Data}).

-define(COUNTER_FIELDS,
        [batches,
         offset,
         committed_offset]).

-spec init(map()) -> {ok, state()}.
init(#{name := Name,
       replica_nodes := Replicas} = Config) ->
    Dir0 = case Config of
              #{dir := D} -> D;
              _ ->
                  {ok, D} = application:get_env(data_dir),
                  D
          end,
    Dir = filename:join(Dir0, Name),
    process_flag(trap_exit, true),
    process_flag(message_queue_data, off_heap),
    filelib:ensure_dir(Dir),
    case file:make_dir(Dir) of
        ok -> ok;
        {error, eexist} -> ok;
        E -> throw(E)
    end,
    ORef = atomics:new(1, []),
    Segment = osiris_segment:init(Dir, Config),
    ExtRef = maps:get(reference, Config, Name),
    CntRef = osiris_counters:new({?MODULE, ExtRef}, ?COUNTER_FIELDS),
    LastOffs = osiris_segment:next_offset(Segment) -1,
    % counters:add(Cnt, 1, 1),
    % counters:add(CntRef, 2, 1),
    atomics:put(ORef, 1, LastOffs),
    counters:add(CntRef, 2, LastOffs),
    counters:add(CntRef, 3, LastOffs),
    {ok, #?MODULE{cfg = #cfg{name = Name,
                             %% reference used for notification
                             %% if not provided use the name
                             ext_reference = ExtRef,

                             offset_ref = ORef,
                             replicas = Replicas,
                             directory  = Dir,
                             %% TODO: there is no GC of counter registrations
                             counter = CntRef},

                  committed_offset = LastOffs,
                  segment = Segment}}.

handle_batch(Commands, #?MODULE{cfg = #cfg{counter = Cnt},
                                segment = Seg0} = State0) ->

    %% filter write commands
    case handle_commands(Commands, State0, {[], [], #{}}) of
        {Entries, Replies, Corrs, State1} ->
            %% incr batch counter
            counters:add(Cnt, 1, 1),
            %% TODO handle empty replicas
            State2 = case Entries of
                         [] ->
                             State1;
                         _ ->
                             ThisBatchOffs = osiris_segment:next_offset(Seg0),
                             Seg = osiris_segment:write(Entries, Seg0),
                             LastOffs = osiris_segment:next_offset(Seg) - 1,
                             %% update written
                             counters:put(Cnt, 2, LastOffs),
                             update_pending(ThisBatchOffs, Corrs,
                                            State1#?MODULE{segment = Seg})
                     end,
            %% write to log and index files
            State = notify_data_listeners(State2),
            {ok, [garbage_collect | Replies], State};
        {stop, normal} ->
            {stop, normal}
    end.

terminate(_, #?MODULE{data_listeners = Listeners}) ->
    [osiris_replica_reader:stop(Pid) || {Pid, _} <- Listeners],
    ok.

format_status(State) ->
    State.

%% Internal

update_pending(BatchOffs, Corrs,
               #?MODULE{cfg = #cfg{ext_reference = Ref,
                                   counter = Cnt,
                                   offset_ref = OffsRef,
                                   replicas = []}} = State0) ->
    _ = notify_writers(Ref, Corrs),
    atomics:put(OffsRef, 1, BatchOffs),
    counters:put(Cnt, 3, BatchOffs),
    State = State0#?MODULE{committed_offset = BatchOffs},
    ok = notify_offset_listeners(State),
    State;
update_pending(BatchOffs, Corrs,
               #?MODULE{cfg = #cfg{replicas = Replicas},
                        pending_writes = Pending0} = State) ->
    case Corrs of
        _  when map_size(Corrs) == 0 ->
            State;
        _ ->
            State#?MODULE{pending_writes =
                          Pending0#{BatchOffs => {Replicas, Corrs}}}
    end.

handle_commands([], State, {Records, Replies, Corrs}) ->
    {lists:reverse(Records), Replies, Corrs, State};
handle_commands([{cast, {write, Pid, Corr, R}} | Rem], State,
                {Records, Replies, Corrs0}) ->
    Corrs = maps:update_with(Pid, fun (C) -> [Corr |  C] end,
                             [Corr], Corrs0),
    handle_commands(Rem, State, {[R | Records], Replies, Corrs});
handle_commands([{cast, {register_data_listener, Pid, Offset}} | Rem],
                #?MODULE{data_listeners = Listeners} = State0, Acc) ->
    State = State0#?MODULE{data_listeners = [{Pid, Offset} | Listeners]},
    handle_commands(Rem, State, Acc);
handle_commands([{cast, {register_offset_listener, Pid}} | Rem],
                #?MODULE{offset_listeners = Listeners} = State0, Acc) ->
    State = State0#?MODULE{offset_listeners = [Pid | Listeners]},
    %% TODO: only notify the newly registered offset listener
    notify_offset_listeners(State),
    handle_commands(Rem, State, Acc);
handle_commands([{cast, {ack, ReplicaNode, Offsets}} | Rem],
                #?MODULE{cfg = #cfg{ext_reference = Ref,
                                    counter = Cnt,
                                    offset_ref = ORef},
                         committed_offset = COffs0,
                         pending_writes = Pending0} = State0, Acc) ->
    % ct:pal("acks ~w", [Offsets]),

    {COffs, Pending} = lists:foldl(
                         fun (Offset, {C0, P0}) ->
                                 case maps:get(Offset, P0) of
                                     {[ReplicaNode], Corrs} ->
                                         _ = notify_writers(Ref, Corrs),
                                         atomics:put(ORef, 1, Offset),
                                         counters:put(Cnt, 3, Offset),
                                         {Offset, maps:remove(Offset, P0)};
                                     {Reps, Corrs} ->
                                         Reps1 = lists:delete(ReplicaNode, Reps),
                                         {C0, maps:update(Offset,
                                                          {Reps1, Corrs},
                                                          P0)}
                                 end
                         end, {COffs0, Pending0}, Offsets),
    % ct:pal("acks after ~w ~W", [COffs, Pending, 5]),
    State = State0#?MODULE{pending_writes = Pending,
                           committed_offset = COffs},
    %% if committed offset has incresed - update 
    case COffs > COffs0 of
        true ->
            ok = notify_offset_listeners(State);
        false ->
            ok
    end,

    handle_commands(Rem, State, Acc);
handle_commands([{call, From, get_reader_context} | Rem],
                #?MODULE{cfg = #cfg{offset_ref = ORef,
                                    directory = Dir},
                         committed_offset = COffs} = State,
                {Records, Replies, Corrs}) ->
    Reply = {reply, From, #{dir => Dir,
                            committed_offset => max(0, COffs),
                            offset_ref => ORef}},
    handle_commands(Rem, State, {Records, [Reply | Replies], Corrs});
handle_commands([{call, From, delete} | _],
                #?MODULE{cfg = #cfg{directory = Dir}}, _) ->
    {ok, Files} = file:list_dir(Dir),
    [ok = file:delete(filename:join(Dir, F)) || F <- Files],
    ok = file:del_dir(Dir),
    gen_server:reply(From, ok),
    {stop, normal};
handle_commands([_Unk | Rem], State, Acc) ->
    error_logger:info_msg("osiris_writer unknown command ~w", [_Unk]),
    handle_commands(Rem, State, Acc).


notify_data_listeners(#?MODULE{segment = Seg,
                               data_listeners = L0} = State) ->
    LastOffset = osiris_segment:next_offset(Seg) - 1,
    {Notify, L} = lists:splitwith(fun ({_Pid, O}) -> O < LastOffset end, L0),
    [gen_server:cast(P, {more_data, LastOffset})
     || {P, _} <- Notify],
    State#?MODULE{data_listeners = L}.

notify_offset_listeners(#?MODULE{cfg = #cfg{ext_reference = Ref},
                                 committed_offset = COffs,
                                 % segment = Seg,
                                 offset_listeners = L0}) ->
    [begin
         % Next = osiris_segment:next_offset(Seg),
         % error_logger:info_msg("osiris_writer offset listner ~w CO: ~w Next ~w LO: ~w",
         %                       [P, COffs, Next, O]),
         P ! {osiris_offset, Ref, COffs}
     end || P <- L0],
    ok.

notify_writers(Name, Corrs) ->
    maps:map(
      fun (P, V) ->
              P ! {osiris_written, Name, lists:reverse(V)}
      end, Corrs).

