%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2009 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2009 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2009 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%


%% This module handles the node-wide memory statistics.
%% It receives statistics from all queues, counts the desired
%% queue length (in seconds), and sends this information back to
%% queues.

-module(rabbit_memory_monitor).

-behaviour(gen_server2).

-export([start_link/0, update/0, register/2, deregister/1,
         report_queue_duration/2, stop/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(process, {pid, reported, sent, callback}).

-record(state, {timer,                %% 'internal_update' timer
                queue_durations,      %% ets #process
                queue_duration_sum,   %% sum of all queue_durations
                queue_duration_count, %% number of elements in sum
                memory_limit,         %% how much memory we intend to use
                desired_duration      %% the desired queue duration
               }).

-define(SERVER, ?MODULE).
-define(DEFAULT_UPDATE_INTERVAL, 2500).
-define(TABLE_NAME, ?MODULE).

%% Because we have a feedback loop here, we need to ensure that we
%% have some space for when the queues don't quite respond as fast as
%% we would like, or when there is buffering going on in other parts
%% of the system. In short, we aim to stay some distance away from
%% when the memory alarms will go off, which cause channel.flow.
%% Note that all other Thresholds are relative to this scaling.
-define(MEMORY_LIMIT_SCALING, 0.6).

-define(LIMIT_THRESHOLD, 0.5). %% don't limit queues when mem use is < this

%% If all queues are pushed to disk (duration 0), then the sum of
%% their reported lengths will be 0. If memory then becomes available,
%% unless we manually intervene, the sum will remain 0, and the queues
%% will never get a non-zero duration.  Thus when the mem use is <
%% SUM_INC_THRESHOLD, increase the sum artificially by SUM_INC_AMOUNT.
-define(SUM_INC_THRESHOLD, 0.95).
-define(SUM_INC_AMOUNT, 1.0).

%% A queue may report a duration of 0, or close to zero, and may be
%% told a duration of infinity (eg if less than LIMIT_THRESHOLD memory
%% is being used). Subsequently, the memory-monitor can calculate the
%% desired duration as zero, or close to zero (eg now more memory is
%% being used, and the sum of durations is very small). If it is a
%% fast moving queue, telling it a very small value will badly hurt
%% it, unnecessarily: a fast moving queue will often oscillate between
%% being empty and having a few thousand msgs in it, representing a
%% few hundred milliseconds. SMALL_INFINITY_OSCILLATION_DURATION is a
%% threshold: if a queue has been told a duration of infinity last
%% time, and it's reporting a value <
%% SMALL_INFINITY_OSCILLATION_DURATION then we send it back a duration
%% of infinity, even if the current desired duration /= infinity. Thus
%% for a queue which has been told infinity, it must report a duration
%% >= SMALL_INFINITY_OSCILLATION_DURATION before it is told a
%% non-infinity duration. This basically forms a threshold which
%% effects faster queues more than slower queues and which accounts
%% for natural fluctuations occurring in the queue length.
-define(SMALL_INFINITY_OSCILLATION_DURATION, 1.0).

%% If user disabled vm_memory_monitor, let's assume 1GB of memory we can use.
-define(MEMORY_SIZE_FOR_DISABLED_VMM, 1073741824).

-define(EPSILON, 0.000001). %% less than this and we clamp to 0

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-spec(start_link/0 :: () -> 'ignore' | {'error', _} | {'ok', pid()}).
-spec(update/0 :: () -> 'ok').
-spec(register/2 :: (pid(), {atom(),atom(),[any()]}) -> 'ok').
-spec(deregister/1 :: (pid()) -> 'ok').
-spec(report_queue_duration/2 :: (pid(), float() | 'infinity') -> number()).
-spec(stop/0 :: () -> 'ok').

-endif.

%%----------------------------------------------------------------------------
%% Public API
%%----------------------------------------------------------------------------

start_link() ->
    gen_server2:start_link({local, ?SERVER}, ?MODULE, [], []).

update() ->
    gen_server2:cast(?SERVER, update).

register(Pid, MFA = {_M, _F, _A}) ->
    gen_server2:call(?SERVER, {register, Pid, MFA}, infinity).

deregister(Pid) ->
    gen_server2:cast(?SERVER, {deregister, Pid}).

report_queue_duration(Pid, QueueDuration) ->
    gen_server2:call(rabbit_memory_monitor,
                     {report_queue_duration, Pid, QueueDuration}, infinity).

stop() ->
    gen_server2:cast(?SERVER, stop).

%%----------------------------------------------------------------------------
%% Gen_server callbacks
%%----------------------------------------------------------------------------

init([]) ->
    MemoryLimit = trunc(get_memory_limit() * ?MEMORY_LIMIT_SCALING),

    {ok, TRef} = timer:apply_interval(?DEFAULT_UPDATE_INTERVAL,
                                      ?SERVER, update, []),

    Ets = ets:new(?TABLE_NAME, [set, private, {keypos, #process.pid}]),

    {ok, internal_update(
           #state{timer                = TRef,
                  queue_durations      = Ets,
                  queue_duration_sum   = 0.0,
                  queue_duration_count = 0,
                  memory_limit         = MemoryLimit,
                  desired_duration     = infinity})}.

handle_call({report_queue_duration, Pid, QueueDuration}, From,
            State = #state{queue_duration_sum = Sum,
                           queue_duration_count = Count,
                           queue_durations = Durations,
                           desired_duration = SendDuration}) ->

    [Proc = #process{reported = PrevQueueDuration, sent = PrevSendDuration}] =
        ets:lookup(Durations, Pid),

    SendDuration1 =
        case QueueDuration /= infinity andalso PrevSendDuration == infinity
            andalso QueueDuration < ?SMALL_INFINITY_OSCILLATION_DURATION of
            true -> infinity;
            false -> SendDuration
        end,
    gen_server2:reply(From, SendDuration1),

    {Sum1, Count1} =
            case {PrevQueueDuration, QueueDuration} of
                {infinity, infinity} -> {Sum, Count};
                {infinity, _}        -> {Sum + QueueDuration,    Count + 1};
                {_, infinity}        -> {Sum - PrevQueueDuration, Count - 1};
                {_, _} -> {Sum - PrevQueueDuration + QueueDuration, Count}
            end,
    true = ets:insert(Durations, Proc#process{reported = QueueDuration,
                                              sent = SendDuration1}),
    {noreply, State#state{queue_duration_sum = zero_clamp(Sum1),
                          queue_duration_count = Count1}};

handle_call({register, Pid, MFA}, _From,
            State = #state{queue_durations = Durations}) ->
    _MRef = erlang:monitor(process, Pid),
    true = ets:insert(Durations, #process{pid = Pid, reported = infinity,
                                          sent = infinity, callback = MFA}),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(update, State) ->
    {noreply, internal_update(State)};

handle_cast({deregister, Pid}, State) ->
    {noreply, internal_deregister(Pid, State)};

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', _MRef, process, Pid, _Reason}, State) ->
    {noreply, internal_deregister(Pid, State)};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{timer = TRef}) ->
    timer:cancel(TRef),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%----------------------------------------------------------------------------
%% Internal functions
%%----------------------------------------------------------------------------

zero_clamp(Sum) ->
    case Sum < ?EPSILON of
        true -> 0.0;
        false -> Sum
    end.

internal_deregister(Pid, State = #state{queue_duration_sum = Sum,
                                        queue_duration_count = Count,
                                        queue_durations = Durations}) ->
    case ets:lookup(Durations, Pid) of
        [] -> State;
        [#process{reported = PrevQueueDuration}] ->
            Sum1 = case PrevQueueDuration of
                       infinity -> Sum;
                       _        -> zero_clamp(Sum - PrevQueueDuration)
                   end,
            true = ets:delete(State#state.queue_durations, Pid),
            State#state{queue_duration_sum = Sum1,
                        queue_duration_count = Count-1}
    end.

internal_update(State = #state{memory_limit = Limit,
                               queue_durations = Durations,
                               desired_duration = DesiredDurationAvg,
                               queue_duration_sum = Sum,
                               queue_duration_count = Count}) ->
    MemoryRatio = erlang:memory(total) / Limit,
    DesiredDurationAvg1 =
        case MemoryRatio < ?LIMIT_THRESHOLD orelse Count == 0 of
            true ->
                infinity;
            false ->
                Sum1 = case MemoryRatio < ?SUM_INC_THRESHOLD of
                           true -> Sum + ?SUM_INC_AMOUNT;
                           false -> Sum
                       end,
                (Sum1 / Count) / MemoryRatio
        end,
    State1 = State#state{desired_duration = DesiredDurationAvg1},

    %% only inform queues immediately if the desired duration has
    %% decreased
    case DesiredDurationAvg1 == infinity orelse
        (DesiredDurationAvg /= infinity andalso
         DesiredDurationAvg1 >= DesiredDurationAvg) of
        true -> ok;
        false ->
            %% If we have pessimistic information, we need to inform
            %% queues to reduce it's memory usage when needed. This
            %% sometimes wakes up queues from hibernation.
            true =
                ets:foldl(
                  fun (Proc = #process{reported = QueueDuration,
                                       sent = PrevSendDuration}, true) ->
                          Send =
                              case {QueueDuration, PrevSendDuration} of
                                  {infinity, infinity} ->
                                      true;
                                  {infinity, B} ->
                                      DesiredDurationAvg1 < B;
                                  {A, infinity} ->
                                      DesiredDurationAvg1 < A andalso A >=
                                          ?SMALL_INFINITY_OSCILLATION_DURATION;
                                  {A, B} ->
                                      DesiredDurationAvg1 < lists:min([A,B])
                              end,
                          case Send of
                              true ->
                                  ok = set_queue_duration(Proc, DesiredDurationAvg1),
                                  ets:insert(
                                    Durations,
                                    Proc#process{sent=DesiredDurationAvg1});
                              false -> true
                          end
                  end, true, Durations)
    end,
    State1.

get_memory_limit() ->
    case vm_memory_monitor:get_memory_limit() of
        undefined -> ?MEMORY_SIZE_FOR_DISABLED_VMM;
        A -> A
    end.

set_queue_duration(#process{callback={M,F,A}}, QueueDuration) ->
    ok = erlang:apply(M, F, A++[QueueDuration]).
