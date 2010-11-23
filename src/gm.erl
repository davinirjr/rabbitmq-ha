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
%%   The Original Code is RabbitMQ-HA.
%%
%%   The Initial Developers of the Original Code are Rabbit Technologies Ltd.
%%
%%   Copyright (C) 2010 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(gm).

%% Guaranteed Multicast
%%
%% This module provides the ability to create named groups of
%% processes to which members can be dynamically added and removed,
%% and for messages to be broadcast within the group that are
%% guaranteed to reach all members of the group during the lifetime of
%% the message. The lifetime of a message is defined as being, at a
%% minimum, the time from which the message is first sent to any
%% member of the group, up until the time at which it is known by the
%% member who created the message that the message has reached all
%% group members.
%%
%% The guarantee given is that provided a message, once sent, makes it
%% to members who do not all leave the group, the message will
%% continue to propogate to all group members, including new group
%% members, provided the new members have joined before the message
%% has reached all members of the group.
%%
%% One possible means of implementation would be a fanout from the
%% sender to every member of the group. This would require that the
%% group is fully connected, and, in the event that the original
%% sender of the message disappears from the group before the message
%% has made it to every member of the group, raises questions as to
%% who is responsible for sending on the message to new group members.
%% In the event that within the group, messages sent are broadcast
%% from a subset of the members, this arrangement has the potential to
%% substantially impact the CPU and network workload of such members,
%% as such members would have to accomodate the cost of sending each
%% message to every group member.
%%
%% Instead, if the members of the group are arranged in a chain, then
%% it makes it much easier to ensure that it is possible to reason
%% about who within the group has received the message and who has
%% not. It eases issues of responsibility: in the event of a group
%% member disappearing, the nearest upstream member of the chain is
%% responsible for ensuring that messages continue to propogate down
%% the chain. It also results in equal distribution of sending and
%% receiving workload, even if all messages are being sent from just a
%% single group member. This configuration has the further advantage
%% that it is not necessary for every group member to know of every
%% other group member, and even that a group member does not have to
%% be accessible from all other group members.
%%
%% Performance is kept high by permitting pipelining and all
%% communication is asynchronous. In the chain A -> B -> C, if A sends
%% a message to the group, it will not directly contact C. However, it
%% must know that C receives the message (in addition to B) before it
%% can consider the message fully sent. A simplistic implementation
%% would require that C replies to B and B then replies to A. This
%% would then mean that the propagation delay is twice the length of
%% the chain. It would also require, in the event of the failure of B,
%% that C knows to directly contact A and issue the necessary
%% replies. Instead, the chain forms a ring: C sends the message on to
%% A: C does not distinguish A as the sender, merely as the next
%% member within the chain. When A receives from C messages that A
%% sent, it knows that all participants have received the
%% message. However, the message is not dead yet: if C died as B was
%% sending to C, then B would need to detect the death of C and
%% forward the message on to A instead: thus every node has to
%% remember every message published to it until it is told that it can
%% forget about the message. This is essential not just for dealing
%% with failure of members, but also for the addition of new members.
%%
%% Thus once A receives the message back again, it then sends to B an
%% acknowledgement for the message, indicating that B can now forget
%% about the message. B does so, and forwards the ack to C. C forgets
%% the message, and forwards the ack back to A. At this point, A takes
%% no further action: the message and its acknowledgement have made it
%% to every member of the group. The message is now dead, and any new
%% member joining the group at this point will not receive the
%% message.
%%
%% We therefore have two roles:
%%
%% 1. The sender, who upon receiving their own messages back, must
%% then send out acknowledgements, and upon receiving their own
%% acknowledgements back perform no further action.
%%
%% 2. The other group members who upon receiving messages and
%% acknowledgements must update their own internal state accordingly
%% (the sending member must also do this in order to be able to
%% accomodate failures).
%%
%% We also have three distinct failure scenarios: imagine the chain of
%% A -> B -> C:
%%
%% 1. If B dies then A must contact C and directly tell C the messages
%% which are unacknowledged and the last acknowledgement seen. This is
%% the normal case for the failure of intermediate members. The list
%% of unacknowledged messages C receives from A may be equal to or a
%% suffix of the list of unacknowledged messages that C knows of:
%% acknowledgements are found from messages C knows of at the head of
%% the list which A has removed, whilst additional publishes are
%% present at the end of A's list which are absent from C's. Thus if
%% C's list of unacknowledged messages is [1,2,3] and the list it
%% receives from A is [3,4] then it knows that it should acknowledge 1
%% and 2, and publish 4.
%%
%% 2. If C dies then A will receive from B all the unacknowledged
%% messages as known by B. However, A, as the sender of messages, must
%% calculate from this the messages B is therefore implying A was
%% about to receive from C, and for which A was then about to issue
%% acknowledgements for. If A has a list of messages pending
%% acknowledgement of [4,5,6] and it receives from B the list of
%% [3,4,5] then it means: A has already sent out the acknowledgement
%% for 3, but it hasn't yet made it to B (no action to take for this -
%% A needs to take no actions concerning acknowledgements that were
%% lost (which C was about to send back to A but failed to do so as C
%% died) - A would have taken no action upon receipt of these messages
%% had they come from C); and that the publication of messages 4 and 5
%% made it to B, but A is yet to acknowledge these messages, and so A
%% should now send out the acknowledgements for messages 4 and 5,
%% reducing its list of messages pending acknowledgement to just
%% [6].
%%
%% 3. If A dies then B must now take responsibility for the actions
%% that A would have performed upon receiving its own messages back
%% (i.e. converting them to acknowledgements and sending them on),
%% plus not sending on any acknowledgements it receives. I.e. B is now
%% in charge of the messages that were still alive when A died. The
%% same scenarios are valid here as in case (2) above: B is sure to
%% know at least as much as any one else about the messages that A
%% sent. Correspondingly, the detection of acknowledgements and
%% publications are the same: B can simply pretend that it sent the
%% messages.
%%
%% In the event of a member joining the chain, they can join at any
%% location within the chain. Their upstream member will send them the
%% unacknowledged messages, which the new member will update its own
%% state with, interpret the messages unacknowledged, but not forward
%% such messages on (as the nearest downstream member would already
%% have been sent such messages).
%%
%% In the example chain A -> B -> C, care must be taken in the event
%% of the death of B, that C does not process any messages it receives
%% from B that were in flight but unreceived at the point of the death
%% of B, _after_ it has established contact from A.
%%
%% Finally, we abstract all the above so that any member of the group
%% can send messages: thus all group members are equal and can
%% simultaneously play the roles of A, B or C from the above
%% description depending solely on whether they or someone else sent
%% each message.
%%
%% Obvious extension points:
%%
%% 1. When sending a message, indicate which members of the group the
%% message is intended for. Everything proceeds as above: the only
%% change is that members not in the recipients list do not invoke
%% their callback for such messages.
%%

-behaviour(gen_server2).

-export([create_tables/0, join/2, leave/1, broadcast/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-define(GROUP_TABLE, gm_group).
-define(HIBERNATE_AFTER_MIN, 1000).
-define(DESIRED_HIBERNATE, 10000).
-define(SETS, ordsets).

-record(state,
        { self,
          left,
          right,
          group_name,
          callback,
          view,
          pub_count,
          members_state,
          pending_join
        }).

-record(gm_group, { name, version, members }).

-record(view_member, { id, aliases, left, right }).

-record(member, { pending_ack, last_pub, last_ack }).

-define(TAG, '$gm').

-define(TABLES,
        [{?GROUP_TABLE, [{record_name, gm_group},
                         {attributes, record_info(fields, gm_group)}]}
        ]).

create_tables() ->
    create_tables(?TABLES).

create_tables([]) ->
    ok;
create_tables([{Table, Attributes} | Tables]) ->
    case mnesia:create_table(Table, Attributes) of
        {atomic, ok}                          -> create_tables(Tables);
        {aborted, {already_exists, gm_group}} -> create_tables(Tables);
        Err                                   -> Err
    end.

join(GroupName, Callback) ->
    gen_server2:start_link(?MODULE, [GroupName, Callback], []).

leave(Server) ->
    gen_server2:cast(Server, leave).

broadcast(Server, Msg) ->
    gen_server2:cast(Server, {broadcast, Msg}).


init([GroupName, Callback]) ->
    process_flag(trap_exit, true),
    random:seed(now()),
    gen_server2:cast(self(), join),
    Self = self(),
    {ok, #state { self          = Self,
                  left          = {Self, undefined},
                  right         = {Self, undefined},
                  group_name    = GroupName,
                  callback      = Callback,
                  view          = undefined,
                  pub_count     = 0,
                  members_state = undefined,
                  pending_join  = queue:new() }, hibernate,
     {backoff, ?HIBERNATE_AFTER_MIN, ?HIBERNATE_AFTER_MIN, ?DESIRED_HIBERNATE}}.


handle_call({add_on_right, _NewMember}, _From,
            State = #state { members_state = undefined }) ->
    reply(not_ready, State);

handle_call({add_on_right, NewMember}, _From,
            State = #state { self          = Self,
                             group_name    = GroupName,
                             members_state = MembersState }) ->
    Group = record_new_member_in_group(
              GroupName, Self, NewMember,
              fun (Group1) ->
                      View1 = group_to_view(Group1),
                      ok = send_right(NewMember, View1,
                                      {catchup, Self, prepare_members_state(
                                                        MembersState)})
              end),
    View = group_to_view(Group),
    reply({ok, Group}, check_neighbours(State #state { view = View })).


handle_cast({?TAG, ReqVer, Msg}, State = #state { self       = Self,
                                                  left       = {Left, _MRefL},
                                                  right      = {Right, _MRefR},
                                                  view       = View,
                                                  group_name = GroupName }) ->
    State1 = case needs_view_update(ReqVer, View) of
                 true ->
                     View1 = group_to_view(read_group(GroupName)),
                     State2 = State #state { view = View1 },
                     case fetch_view_member(Self, View1) of
                         #view_member { left = Left, right = Right } ->
                             State2;
                         _ ->
                             check_neighbours(State2)
                     end;
                 false ->
                     State
             end,
    noreply(handle_msg(Msg, State1));

handle_cast({broadcast, Msg}, State = #state { self          = Self,
                                               right         = Right,
                                               members_state = MembersState,
                                               pending_join  = PendingJoin,
                                               pub_count     = PubCount })
  when Right =:= {Self, undefined} orelse MembersState =:= undefined ->
    noreply(
      State #state { pending_join = queue:in({PubCount, Msg}, PendingJoin),
                     pub_count    = PubCount + 1 });

handle_cast({broadcast, Msg},
            State = #state { self          = Self,
                             right         = {Right, _MRefR},
                             view          = View,
                             pub_count     = PubCount,
                             members_state = MembersState }) ->
    PubMsg = {PubCount, Msg},
    Activity = activity_cons(Self, [PubMsg], [], activity_nil()),
    ok = send_activity(Self, Right, View, Activity),
    MembersState1 =
        with_member(
          fun (Member = #member { pending_ack = PA }) ->
                  Member #member { pending_ack = queue:in(PubMsg, PA) }
          end, Self, MembersState),
    noreply(State #state { members_state = MembersState1,
                           pub_count     = PubCount + 1 });

handle_cast(join, State = #state { self       = Self,
                                   group_name = GroupName }) ->
    View = join_group(Self, GroupName),
    noreply(check_neighbours(State #state { view = View }));

handle_cast(leave, State) ->
    {stop, normal, State}.


handle_msg(check_neighbours, State) ->
    %% no-op - it's already been done by the calling handle_cast
    State;

handle_msg({catchup, Left, MembersStateLeft},
           State = #state { self          = Self,
                            left          = {Left, _MRefL},
                            right         = {Right, _MRefR},
                            view          = View,
                            members_state = undefined,
                            pending_join  = PendingJoin }) ->
    ok = send_right(Right, View, {catchup, Self, MembersStateLeft}),
    MembersStateLeft1 = build_members_state(MembersStateLeft),
    case queue:to_list(PendingJoin) of
        [] ->
            State #state { members_state = MembersStateLeft1 };
        Pubs ->
            Activity = activity_cons(Self, Pubs, [], activity_nil()),
            ok = send_activity(Self, Right, View, Activity),
            MembersState2 =
                with_member(fun (Member) ->
                                    Member #member { pending_ack = PendingJoin }
                            end, Self, MembersStateLeft1),
            State #state { members_state = MembersState2,
                           pending_join  = queue:new() }
    end;

handle_msg({catchup, Left, MembersStateLeft},
           State = #state { self = Self,
                            left = {Left, _MRefL},
                            view = View,
                            members_state = MembersState })
  when MembersState =/= undefined ->
    MembersStateLeft1 = build_members_state(MembersStateLeft),
    AllMembers = lists:usort(dict:fetch_keys(MembersState) ++
                                 dict:fetch_keys(MembersStateLeft1)),
    {MembersState1, Activity} =
        lists:foldl(
          fun (Id, MembersStateActivity) ->
                  #member { pending_ack = PALeft, last_ack = LA } =
                      find_member_or_blank(Id, MembersStateLeft1),
                  with_member_acc(
                    fun (#member { pending_ack = PA } = Member, Activity1) ->
                            case is_member_alias(Id, Self, View) of
                                true ->
                                    {_AcksInFlight, Pubs, _PA1} =
                                        find_prefix_common_suffix(PALeft, PA),
                                    {Member #member { last_ack = LA },
                                     activity_cons(Id, pubs_from_queue(Pubs),
                                                   [], Activity1)};
                                false ->
                                    {Acks, _Common, Pubs} =
                                        find_prefix_common_suffix(PA, PALeft),
                                    {Member,
                                     activity_cons(Id, pubs_from_queue(Pubs),
                                                   acks_from_queue(Acks),
                                                   Activity1)}
                            end
                    end, Id, MembersStateActivity)
          end, {MembersState, activity_nil()}, AllMembers),
    State1 = handle_msg({activity, Left, activity_finalise(Activity)},
                        State #state { members_state = MembersState1 }),
    %% we can only tidy up when we know we've receive all pubs for
    %% inherited members
    maybe_erase_aliases(State1);

handle_msg({catchup, _NotLeft, _MembersState}, State) ->
    State;

handle_msg({activity, Left, Activity},
           State = #state { self          = Self,
                            left          = {Left, _MRefL},
                            callback      = Callback,
                            view          = View,
                            members_state = MembersState })
  when MembersState =/= undefined ->
    {MembersState1, Activity1} =
        lists:foldl(
          fun ({Id, Pubs, Acks}, MembersStateActivity) ->
                  with_member_acc(
                    fun (Member = #member { pending_ack = PA,
                                            last_pub    = LP,
                                            last_ack    = LA }, Activity2) ->
                            case is_member_alias(Id, Self, View) of
                                true ->
                                    {ToAck, PA1} =
                                        find_common(queue_from_pubs(Pubs), PA,
                                                    queue:new()),
                                    LA1 = last_ack(Acks, LA),
                                    {Member #member { pending_ack = PA1,
                                                      last_ack    = LA1 },
                                     activity_cons(
                                       Id, [], acks_from_queue(ToAck),
                                       Activity2)};
                                false ->
                                    PA1 = apply_acks(Acks, join_pubs(PA, Pubs)),
                                    LA1 = last_ack(Acks, LA),
                                    LP1 = last_pub(Pubs, LP),
                                    {Member #member { pending_ack = PA1,
                                                      last_pub    = LP1,
                                                      last_ack    = LA1 },
                                     activity_cons(Id, Pubs, Acks, Activity2)}
                            end
                    end, Id, MembersStateActivity)
          end, {MembersState, activity_nil()}, Activity),
    State1 = State #state { members_state = MembersState1 },
    Activity3 = activity_finalise(Activity1),
    ok = maybe_send_activity(Activity3, State1),
    ok = callback(Callback, Activity3),
    State1;

handle_msg({activity, _NotLeft, _Activity}, State) ->
    State.


handle_info({'DOWN', MRef, process, _Pid, _Reason},
            State = #state { left       = Left,
                             right      = Right,
                             group_name = GroupName }) ->
    Member = case {Left, Right} of
                 {{Member1, MRef}, _} -> Member1;
                 {_, {Member1, MRef}} -> Member1;
                 _                    -> undefined
             end,
    case Member of
        undefined ->
            noreply(State);
        _ ->
            View =
                group_to_view(record_dead_member_in_group(Member, GroupName)),
            noreply(check_neighbours(State #state { view = View }))
    end.


terminate(normal, _State) ->
    ok;
terminate(Reason, State) ->
    io:format("~p died~n~p~nreason: ~p~nstate: ~p~n",
              [self(), read_group(State#state.group_name), Reason, State]),
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


noreply(State) ->
    ok = a(State),
    {noreply, State, hibernate}.

reply(Reply, State) ->
    ok = a(State),
    {reply, Reply, State, hibernate}.

a(#state { view = undefined }) ->
    ok;
a(#state { self = Self,
           left = {Left, _MRefL},
           view = View }) ->
    #view_member { left = Left } = fetch_view_member(Self, View),
    ok.

%% ---------------------------------------------------------------------------
%% View construction and inspection
%% ---------------------------------------------------------------------------

needs_view_update(ReqVer, {Ver, _View}) ->
    Ver < ReqVer.

view_version({Ver, _View}) ->
    Ver.

is_member_alive({dead, _Member}) -> false;
is_member_alive(_)               -> true.

is_member_alias(Self, Self, _View) ->
    true;
is_member_alias(Member, Self, View) ->
    ?SETS:is_element(Member,
                     ((fetch_view_member(Self, View)) #view_member.aliases)).

dead_member_id({dead, Member}) -> Member.

store_view_member(VMember = #view_member { id = Id }, {Ver, View}) ->
    {Ver, dict:store(Id, VMember, View)}.

with_view_member(Fun, View, Id) ->
    store_view_member(Fun(fetch_view_member(Id, View)), View).

fetch_view_member(Id, {_Ver, View}) ->
    dict:fetch(Id, View).

find_view_member(Id, {_Ver, View}) ->
    dict:find(Id, View).

blank_view(Ver) ->
    {Ver, dict:new()}.

group_to_view(#gm_group { members = Members, version = Ver }) ->
    Alive = lists:filter(fun is_member_alive/1, Members),
    [_|_] = Alive, %% ASSERTION - can't have all dead members
    add_aliases(link_view(Alive ++ Alive ++ Alive, blank_view(Ver)), Members).

link_view([Left, Middle, Right | Rest], View) ->
    case find_view_member(Middle, View) of
        error ->
            link_view(
              [Middle, Right | Rest],
              store_view_member(#view_member { id      = Middle,
                                               aliases = ?SETS:new(),
                                               left    = Left,
                                               right   = Right }, View));
        {ok, _} ->
            View
    end;
link_view(_, View) ->
    View.

add_aliases(View, Members) ->
    Members1 = ensure_alive_suffix(Members),
    {EmptyDeadSet, View1} =
        lists:foldl(
          fun (Member, {DeadAcc, ViewAcc}) ->
                  case is_member_alive(Member) of
                      true ->
                          {?SETS:new(),
                           with_view_member(
                             fun (VMember =
                                      #view_member { aliases = Aliases }) ->
                                     VMember #view_member {
                                       aliases = ?SETS:union(Aliases, DeadAcc) }
                             end, ViewAcc, Member)};
                      false ->
                          {?SETS:add_element(dead_member_id(Member), DeadAcc),
                           ViewAcc}
                  end
          end, {?SETS:new(), View}, Members1),
    0 = ?SETS:size(EmptyDeadSet), %% ASSERTION
    View1.

ensure_alive_suffix(Members) ->
    queue:to_list(ensure_alive_suffix1(queue:from_list(Members))).

ensure_alive_suffix1(MembersQ) ->
    {{value, Member}, MembersQ1} = queue:out_r(MembersQ),
    case is_member_alive(Member) of
        true  -> MembersQ;
        false -> ensure_alive_suffix1(queue:in_r(Member, MembersQ1))
    end.


%% ---------------------------------------------------------------------------
%% View modification
%% ---------------------------------------------------------------------------

join_group(Self, GroupName) ->
    join_group(Self, GroupName, read_group(GroupName)).

join_group(Self, GroupName, {error, not_found}) ->
    join_group(Self, GroupName, prune_or_create_group(Self, GroupName));
join_group(Self, _GroupName, #gm_group { members = [Self] } = Group) ->
    group_to_view(Group);
join_group(Self, GroupName, #gm_group { members = Members } = Group) ->
    case lists:member(Self, Members) of
        true ->
            group_to_view(Group);
        false ->
            case lists:filter(fun is_member_alive/1, Members) of
                [] ->
                    join_group(Self, GroupName,
                               prune_or_create_group(Self, GroupName));
                Alive ->
                    Left = lists:nth(random:uniform(length(Alive)), Alive),
                    try
                        case gen_server2:call(
                               Left, {add_on_right, Self}, infinity) of
                            {ok, Group1} -> group_to_view(Group1);
                            not_ready    -> join_group(Self, GroupName)
                        end
                    catch
                        exit:{R, _} when R =:= noproc; R =:= normal; R =:= shutdown ->
                            join_group(
                              Self, GroupName,
                              record_dead_member_in_group(Left, GroupName))
                    end
            end
    end.

read_group(GroupName) ->
    case mnesia:dirty_read(?GROUP_TABLE, GroupName) of
        []      -> {error, not_found};
        [Group] -> Group
    end.

prune_or_create_group(Self, GroupName) ->
    {atomic, Group} =
        mnesia:sync_transaction(
          fun () -> GroupNew = #gm_group { name    = GroupName,
                                           members = [Self],
                                           version = 0 },
                    case mnesia:read(?GROUP_TABLE, GroupName) of
                        [] ->
                            mnesia:write(GroupNew),
                            GroupNew;
                        [Group1 = #gm_group { members = Members }] ->
                            case lists:any(fun is_member_alive/1, Members) of
                                true  -> Group1;
                                false -> mnesia:write(GroupNew),
                                         GroupNew
                            end
                    end
          end),
    Group.

record_dead_member_in_group(Member, GroupName) ->
    {atomic, Group} =
        mnesia:sync_transaction(
          fun () -> [Group1 = #gm_group { members = Members, version = Ver }] =
                        mnesia:read(?GROUP_TABLE, GroupName),
                    case lists:splitwith(
                           fun (Member1) -> Member1 =/= Member end, Members) of
                        {_Members1, []} -> %% not found - already recorded dead
                            Group1;
                        {Members1, [Member | Members2]} ->
                            Members3 = Members1 ++ [{dead, Member} | Members2],
                            Group2 = Group1 #gm_group { members = Members3,
                                                        version = Ver + 1 },
                            mnesia:write(Group2),
                            Group2
                    end
          end),
    Group.

record_new_member_in_group(GroupName, Left, NewMember, Fun) ->
    {atomic, Group} =
        mnesia:sync_transaction(
          fun () ->
                  [#gm_group { members = Members, version = Ver } = Group1] =
                      mnesia:read(?GROUP_TABLE, GroupName),
                  {Prefix, [Left | Suffix]} =
                      lists:splitwith(fun (M) -> M =/= Left end, Members),
                  Members1 = Prefix ++ [Left, NewMember | Suffix],
                  Group2 = Group1 #gm_group { members = Members1,
                                              version = Ver + 1 },
                  ok = Fun(Group2),
                  mnesia:write(Group2),
                  Group2
          end),
    Group.

erase_members_in_group(Members, GroupName) ->
    DeadMembers = [{dead, Id} || Id <- Members],
    {atomic, Group} =
        mnesia:sync_transaction(
          fun () ->
                  [Group1 = #gm_group { members = [_|_] = Members1,
                                        version = Ver }] =
                      mnesia:read(?GROUP_TABLE, GroupName),
                  case Members1 -- DeadMembers of
                      Members1 -> Group1;
                      Members2 -> Group2 =
                                      Group1 #gm_group { members = Members2,
                                                         version = Ver + 1 },
                                  mnesia:write(Group2),
                                  Group2
                  end
          end),
    Group.

maybe_erase_aliases(State = #state { self          = Self,
                                     group_name    = GroupName,
                                     view          = View,
                                     members_state = MembersState }) ->
    #view_member { aliases = Aliases } = fetch_view_member(Self, View),
    {Erasable, MembersState1}
        = ?SETS:fold(
            fun (Id, {ErasableAcc, MembersStateAcc} = Acc) ->
                    #member { last_pub = LP, last_ack = LA } =
                        find_member_or_blank(Id, MembersState),
                    case can_erase_view_member(Self, Id, LA, LP) of
                        true  -> {[Id | ErasableAcc],
                                  erase_member(Id, MembersStateAcc)};
                        false -> Acc
                    end
            end, {[], MembersState}, Aliases),
    case Erasable of
        [] -> ok;
        _  -> erase_members_in_group(Erasable, GroupName)
    end,
    State #state { members_state = MembersState1 }.

can_erase_view_member(Self, Self, _LA, _LP) ->
    false;
can_erase_view_member(_Self, _Id, N, N) ->
    true;
can_erase_view_member(_Self, _Id, _LA, _LP) ->
    false.


%% ---------------------------------------------------------------------------
%% View monitoring and maintanence
%% ---------------------------------------------------------------------------

ensure_neighbour(_Ver, Self, {Self, undefined}, Self) ->
    {Self, undefined};
ensure_neighbour(Ver, Self, {Self, undefined}, RealNeighbour) ->
    ok = gen_server2:cast(RealNeighbour, {?TAG, Ver, check_neighbours}),
    {RealNeighbour, maybe_monitor(RealNeighbour, Self)};
ensure_neighbour(_Ver, _Self, {RealNeighbour, MRef}, RealNeighbour) ->
    {RealNeighbour, MRef};
ensure_neighbour(Ver, Self, {RealNeighbour, MRef}, Neighbour) ->
    true = erlang:demonitor(MRef),
    Msg = {?TAG, Ver, check_neighbours},
    ok = gen_server2:cast(RealNeighbour, Msg),
    ok = case Neighbour of
             Self -> ok;
             _    -> gen_server2:cast(Neighbour, Msg)
         end,
    {Neighbour, maybe_monitor(Neighbour, Self)}.

maybe_monitor(Self, Self) ->
    undefined;
maybe_monitor(Other, _Self) ->
    erlang:monitor(process, Other).

check_neighbours(State = #state { self          = Self,
                                  left          = Left,
                                  right         = Right,
                                  view          = View,
                                  members_state = MembersState }) ->
    #view_member { left = VLeft, right = VRight }
        = fetch_view_member(Self, View),
    Ver = view_version(View),
    Left1 = ensure_neighbour(Ver, Self, Left, VLeft),
    Right1 = ensure_neighbour(Ver, Self, Right, VRight),
    MembersState1 =
        case {Left1, Right1} of
            {{Self, undefined}, {Self, undefined}} -> blank_member_state();
            _                                      -> MembersState
        end,
    State1 = State #state { left = Left1, right = Right1,
                            members_state = MembersState1 },
    ok = maybe_send_catchup(Right, State1),
    State1.

maybe_send_catchup(Right, #state { right = Right }) ->
    ok;
maybe_send_catchup(_Right, #state { self  = Self,
                                    right = {Self, undefined} }) ->
    ok;
maybe_send_catchup(_Right, #state { members_state = undefined }) ->
    ok;
maybe_send_catchup(_Right, #state { self          = Self,
                                    right         = {Right, _MRef},
                                    view          = View,
                                    members_state = MembersState }) ->
    send_right(Right, View,
               {catchup, Self, prepare_members_state(MembersState)}).


%% ---------------------------------------------------------------------------
%% Catch_up delta detection
%% ---------------------------------------------------------------------------

find_prefix_common_suffix(A, B) ->
    {Prefix, A1} = find_prefix(A, B, queue:new()),
    {Common, Suffix} = find_common(A1, B, queue:new()),
    {Prefix, Common, Suffix}.

%% Returns the elements of A that occur before the first element of B,
%% plus the remainder of A.
find_prefix(A, B, Prefix) ->
    case {queue:out(A), queue:out(B)} of
        {{{value, Val}, _A1}, {{value, Val}, _B1}} ->
            {Prefix, A};
        {{empty, A1}, {{value, _A}, _B1}} ->
            {Prefix, A1};
        {{{value, {NumA, _MsgA} = Val}, A1},
         {{value, {NumB, _MsgB}}, _B1}} when NumA < NumB ->
            find_prefix(A1, B, queue:in(Val, Prefix));
        {_, {empty, _B1}} ->
            {A, Prefix} %% Prefix well be empty here
    end.

%% A should be a prefix of B. Returns the commonality plus the
%% remainder of B.
find_common(A, B, Common) ->
    case {queue:out(A), queue:out(B)} of
        {{{value, Val}, A1}, {{value, Val}, B1}} ->
            find_common(A1, B1, queue:in(Val, Common));
        {{empty, _A}, _} ->
            {Common, B}
    end.


%% ---------------------------------------------------------------------------
%% Members helpers
%% ---------------------------------------------------------------------------

with_member(Fun, Id, MembersState) ->
    store_member(
      Id, Fun(find_member_or_blank(Id, MembersState)), MembersState).

with_member_acc(Fun, Id, {MembersState, Acc}) ->
    {MemberState, Acc1} = Fun(find_member_or_blank(Id, MembersState), Acc),
    {store_member(Id, MemberState, MembersState), Acc1}.

find_member_or_blank(Id, MembersState) ->
    case dict:find(Id, MembersState) of
        {ok, Result} -> Result;
        error        -> blank_member()
    end.

erase_member(Id, MembersState) ->
    dict:erase(Id, MembersState).

blank_member() ->
    #member { pending_ack = queue:new(), last_pub = -1, last_ack = -1 }.

blank_member_state() ->
    dict:new().

store_member(Id, MemberState, MembersState) ->
    dict:store(Id, MemberState, MembersState).

prepare_members_state(MembersState) ->
    dict:to_list(MembersState).

build_members_state(MembersStateList) ->
    dict:from_list(MembersStateList).


%% ---------------------------------------------------------------------------
%% Activity assembly
%% ---------------------------------------------------------------------------

activity_nil() ->
    queue:new().

activity_cons(_Id, [], [], Tail) ->
    Tail;
activity_cons(Sender, Pubs, Acks, Tail) ->
    queue:in({Sender, Pubs, Acks}, Tail).

activity_finalise(Activity) ->
    queue:to_list(Activity).

maybe_send_activity([], _State) ->
    ok;
maybe_send_activity(Activity, #state { self  = Self,
                                       right = {Right, _MRefR},
                                       view  = View }) ->
    ok = gen_server2:cast(
           Right, {?TAG, view_version(View), {activity, Self, Activity}}).

send_activity(Self, Right, View, Activity) ->
    ok = send_right(Right, View, {activity, Self, activity_finalise(Activity)}).

send_right(Right, View, Msg) ->
    ok = gen_server2:cast(Right, {?TAG, view_version(View), Msg}).

callback(Callback, Activity) ->
    [Callback(Id, Pub) || {Id, Pubs, _Acks} <- Activity,
                          {_PubNum, Pub} <- Pubs],
    ok.


%% ---------------------------------------------------------------------------
%% Msg transformation
%% ---------------------------------------------------------------------------

acks_from_queue(Q) ->
    [PubNum || {PubNum, _Msg} <- queue:to_list(Q)].

pubs_from_queue(Q) ->
    queue:to_list(Q).

queue_from_pubs(Pubs) ->
    queue:from_list(Pubs).

apply_acks([], Pubs) ->
    Pubs;
apply_acks([PubNum | Acks], Pubs) ->
    {{value, {PubNum, _Msg}}, Pubs1} = queue:out(Pubs),
    apply_acks(Acks, Pubs1).

join_pubs(Q, []) ->
    Q;
join_pubs(Q, Pubs) ->
    queue:join(Q, queue_from_pubs(Pubs)).

last_ack([], LA) ->
    LA;
last_ack(List, LA) ->
    LA1 = lists:last(List),
    true = LA1 > LA, %% ASSERTION
    LA1.

last_pub([], LP) ->
    LP;
last_pub(List, LP) ->
    {PubNum, _Msg} = lists:last(List),
    true = PubNum > LP, %% ASSERTION
    PubNum.
