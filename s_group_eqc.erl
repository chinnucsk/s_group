%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                      %%
%%  DISCLAIMER:  This is work in progress.              %%
%%                                                      %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% The module is for testing s_group APIs using QuickCheck.
%% The node on which this test in run should start as a 
%% hidden node.

%% Things to add:
%%    precondtions for each command. 

-module(s_group_eqc).

-include_lib("eqc/include/eqc.hrl").

-include_lib("eqc/include/eqc_statem.hrl").

-compile(export_all).

%% eqc callbacks
-export([initial_state/0, 
         command/1,
         precondition/2,
         postcondition/3,
         next_state/3]).

-export([prop_s_group/0,
         register_name/2,
         whereis_name/2,
         send/2]).

%% since the type node() is used by Erlang, I use a_node() here.
-record(model, {groups             =[] :: [group()],
                free_groups        =[] ::[free_group()],
                free_hidden_groups =[]  ::[free_hidden_group()],
                nodes              =[]  ::[a_node()]}).  

-record(state, {ref  =[]  ::[{pid(),[node_id()],[tuple()]}], 
                model     ::#model{}
               }).

-type group()::{s_group_name(), [node_id()], namespace()}.
-type s_group_name()::atom().
-type node_id()::node().
-type namespace()::[{atom(), pid()}].

-type free_group()::{[node_id()], namespace()}.

-type free_hidden_group()::{node_id(), namespace()}. 
  
-type a_node()::{node_id(), connections(), gr_names()}.
-type gr_names()::free_normal_group|free_hidden_group|[s_group_name()].

-type connections()::[connection()].
-type connection()::{node_id(), connection_type()}.
-type connection_type()::visible|hidden.


-define(debug, 1).

%%-define(debug, -1).
-ifdef(debug). 
dbg(Level, F, A) when Level >= ?debug ->
    io:format("dbg:~p:", [now()]),
    io:format(F, A),
    ok;
dbg(_, _, _) ->
    ok.
-define(dbg(Level, F, A), dbg((Level), (F), (A))).
-else.
-define(dbg(Level, F, A), ok).
-endif.


%% We model what we believe the state of the system is 
%% and check whether action on real state has same effect 
%% as on the model.
%%===============================================================
%% Prop
%%===============================================================
prop_s_group() ->
    ?SETUP
       (fun()-> setup(),
                fun()->teardown() end
        end,
        ?FORALL(Cmds,commands(?MODULE),
                begin
                    {_H,_S,Res} = run_commands(?MODULE,Cmds),
                    teardown(),
                    setup(),
                    Res==ok
                end)).

%%===============================================================
%% eqc callbacks
%%===============================================================
%%---------------------------------------------------------------
%% Returns the state in which each test case starts.
%%---------------------------------------------------------------
%% The number of nodes and the free hidden nodes are fixed here. 
%% Could be more random.
%% Here is the configuration file used.
%% [{kernel, 
%%   [{s_groups,
%%    [{group1, normal,  ['node1@127.0.0.1', 'node2@127.0.0.1',
%%                        'node3@127.0.0.1','node4@127.0.0.1']},
%%     {group2, normal,  ['node3@127.0.0.1', 'node4@127.0.0.1',
%%                        'node5@127.0.0.1', 'node6@127.0.0.1']},
%%     {group3, normal,  ['node4@127.0.0.1',  'node6@127.0.0.1',
%%                        'node7@127.0.0.1',  'node8@127.0.0.1']
%%     }]}]}].

-spec initial_state()->#state{}.
initial_state()->
    ?dbg(1, "calling initial state ...\n", []),
    NodeIds = [make_node_id(N)||N<-lists:seq(1,14)],
    
    FreeHiddenGrps = [{make_node_id(N), []}
                      ||N<-[9, 10]],  
    FreeNormalGrps = [{[make_node_id(N)], []}
                      ||N<-[11, 12,13,14]],
    {ok, [Config]} = file:consult("s_group.config"),
    {kernel, Kernel}=lists:keyfind(kernel, 1, Config),
    {s_groups, Grps} = lists:keyfind(s_groups, 1, Kernel),
    SGrps = [{Name, Nids, []}||{Name, _, Nids}<-Grps],
    Nodes=[{NodeId, connections(NodeId), 
            [Name||{Name, _, Nids}<-Grps, 
                   lists:member(NodeId, Nids)]}||NodeId<-NodeIds],
    NodeStates=fetch_node_states(NodeIds),
    Model=#model{groups = SGrps, 
                 free_groups = FreeNormalGrps,
                 free_hidden_groups=FreeHiddenGrps,
                 nodes=Nodes},
    #state{ref=NodeStates, model=Model}.

make_node_id(N)->
    list_to_atom("node"++integer_to_list(N)++"@127.0.0.1").
    

%%---------------------------------------------------------------
%% command: generates an appropriate symbolic function call to appear next
%% in a test case, if the symbolic state is S. Test sequences are generated 
%% by using command(S) repeatedly. However, generated calls are only included 
%% in test sequences if their precondition is also true.
%%---------------------------------------------------------------
command(S) ->
    noshrink(oneof([{call, ?MODULE, register_name,[gen_register_name_pars(S),
                                                   all_node_ids(S)]}
                    %% {call, ?MODULE, re_register_name, [gen_re_register_name_pars(S),
                    %%                                    all_node_ids(S)]}
           %% ,{call, ?MODULE, whereis_name, [gen_whereis_name_pars(S),  all_node_ids(S)]}
           %% ,{call, ?MODULE, send,[gen_send_pars(S),all_node_ids(S)]}
          ])).
 
%%---------------------------------------------------------------
%% precondition: returns true if the symbolic call C can be performed 
%% in the state S. Preconditions are used to decide whether or not to 
%% include candidate commands in test cases
%%---------------------------------------------------------------
precondition(_S, {call, ?MODULE, register_name,
                  [{RegName, _SGroupName, Pid, CurNode}, _AllNodeIds]}) ->
    proc_is_alive(CurNode, Pid) andalso   RegName/=undefined;

precondition(_S, {call, ?MODULE, re_register_name,
                  [{RegName, _SGroupName, Pid, CurNode}, _AllNodeIds]}) ->
    proc_is_alive(CurNode, Pid) andalso  RegName/=undefined;

precondition(S, {call, ?MODULE, whereis_name, 
                 [{_NodeId, _RegName, _SGroupName, 
                   _CurNode}, _AllNodeIds]}) ->
    Model = S#state.model,
    Grps = Model#model.groups,
    Grps/=[]; 
precondition(S, {call, ?MODULE, send, 
                  [{_NodeId, _RegName, _SGroupName, _Msg, 
                   _CurNode}, _AllNodeIds]}) ->
    Model = S#state.model,
    Grps = Model#model.groups,
    Grps /=[];
precondition(_S, _C) ->
    true.

%%---------------------------------------------------------------
%% Checks the postcondition of symbolic call C, executed in 
%% dynamic state S, 
%% with result R. The arguments of the symbolic call are the actual 
%% values passed, not any symbolic expressions from which they were 
%% computed. Thus when a postcondition is checked, we know the function 
%% called, the values it was passed, the value it returned, 
%% and the state in which it was called. Of course, postconditions are 
%% checked during test execution, not test generation.
%%---------------------------------------------------------------
%% Here the state 'S' is the state before the call.
postcondition(S,  {call, ?MODULE, register_name, 
                   [{RegName, SGroupName, Pid, _CurNode}, _AllNodeIds]},
              {Res, ActualState}) ->
    ?dbg(10, "Cmd:~p\n", [{call, ?MODULE, register_name,
                            [{RegName, SGroupName, Pid}]}]),
    Model = S#state.model,
    Grps=Model#model.groups,
    case lists:keyfind(SGroupName,1, Grps) of 
        {SGroupName, NodeIds, NameSpace} ->
            case lists:keyfind(RegName, 1, NameSpace) of 
                {RegName, _} ->
                    ?dbg(0, "Name already used.\n",[]),
                    Res==no andalso
                        is_the_same(ActualState,S);
                false ->
                    ?dbg(0, "Name is fresh.\n", []),
                    case lists:keyfind(Pid,2,NameSpace) of 
                        {_, Pid} ->
                            ?dbg(0, "Pid is already registered.\n", []),
                            Res==no andalso is_the_same(ActualState,S);
                        false ->
                            ?dbg(0, "NameSpace:~p\n", [NameSpace]),
                            ?dbg(0, "Pid is NOT registered.\n", []),
                            NewGrp={SGroupName,NodeIds, [{RegName, Pid}|NameSpace]},
                            NewGrps = lists:keyreplace(SGroupName, 1, Grps, NewGrp),
                            NewModel =Model#model{groups=NewGrps},
                            ?dbg(0,"NewModel:~p\n", [NewModel#model.groups]),
                            NewS=S#state{model=NewModel},
                            Res==yes andalso is_the_same(ActualState,NewS) 
                                andalso prop_partition(NewS)
                        end
            end;
        false ->
            ?dbg(0, "Invalid s_group name.\n", []),
            (Res==no)  and
                is_the_same(ActualState,S)
    end;
postcondition(S,  {call, ?MODULE, re_register_name, 
                   [{RegName, SGroupName, Pid, _CurNode}, _AllNodeIds]},
              {Res, ActualState}) ->
    ?dbg(10, "PostCmd:~p\n", [{call, ?MODULE, re_register_name,
                            [{RegName, SGroupName, Pid}]}]),
    Model = S#state.model,
    Grps=Model#model.groups,
    case lists:keyfind(SGroupName,1, Grps) of 
        {SGroupName, NodeIds, NameSpace} ->
            case lists:keyfind(Pid,2,NameSpace) of 
                {_, Pid} ->  %% Maybe this should be allow?!!
                    ?dbg(10, "Pid is already registered.\n", []),
                    Res==no andalso is_the_same(ActualState,S);
                false ->
                    ?dbg(10, "NameSpace:~p\n", [NameSpace]),
                    ?dbg(10, "Pid is NOT registered.\n", []),
                    NewNameSpace= [{RegName, Pid}|
                                   lists:keydelete(RegName, 1, NameSpace)],
                    NewGrp={SGroupName,NodeIds, NewNameSpace},
                    NewGrps = lists:keyreplace(
                                SGroupName, 1, Grps, NewGrp),
                    NewModel = Model#model{groups=NewGrps},
                    ?dbg(10,"NewModel:~p\n", [NewModel#model.groups]),
                    NewS=S#state{model=NewModel},
                    Res==yes andalso is_the_same(ActualState,NewS) 
                        andalso prop_partition(NewS)
            end;
        false ->
            ?dbg(0, "Invalid s_group name.\n", []),
            (Res==no)  and
                is_the_same(ActualState,S)
    end;
postcondition(S, {call, ?MODULE, whereis_name, 
                   [{TargetNodeId, RegName, GroupName, CurNode}, _AllNodeIds]},
              {Res, ActualState}) ->
    Pid = find_name(S#state.model, TargetNodeId, GroupName,RegName), 
    NewS=whereis_name_next_state(S, CurNode, TargetNodeId),
    Pid == Res andalso is_the_same(ActualState, NewS);   
postcondition(_S, {call, ?MODULE, send, 
                   [{_NodeId, _RegName, _SGroupName, _Msg,_CurNode}, _AllNodeIds]},
              {_Res, _ActualState}) ->
    true;
postcondition(_S, _C, _R) ->
    true.


%%---------------------------------------------------------------
%% This is the state transition function of the abstract state machine, 
%% and it is used during both test generation and test execution.
%%---------------------------------------------------------------
%%-spec(next_state(S::#state{}, R::var(), C::call()) -> #state{}).

%% TOfix: this does not update its ?? 
next_state(S, _V, {call, ?MODULE, register_name, 
                   [{RegName, SGroupName, Pid, _CurNode}, _AllNodeIds]}) ->
    ?dbg(10, "State Cmd:~p\n", [{call, ?MODULE, register_name,
                           [{RegName, SGroupName, Pid}]}]),
    Model = S#state.model,
    #model{groups=Grps}=Model,
    case lists:keyfind(SGroupName, 1, Grps) of 
        {SGroupName, NodeIds, NameSpace} -> 
            case lists:keyfind(RegName, 1, NameSpace) of 
                {RegName, _} ->
                    S;
                false ->
                    case lists:keyfind(Pid,2,NameSpace) of 
                        {_, Pid} -> 
                            S;
                        false ->
                            NewGrp={SGroupName,NodeIds, 
                                    [{RegName, Pid}|NameSpace]},
                            NewGrps = lists:keyreplace(SGroupName, 1, 
                                                       Grps, NewGrp),
                            NewModel = Model#model{groups=NewGrps},
                            S#state{model=NewModel};
                        _ -> S
                    end
            end;
             false -> S
    end;
next_state(S, _V, {call, ?MODULE, re_register_name, 
                   [{RegName, SGroupName, Pid, _CurNode}, _AllNodeIds]}) ->
    ?dbg(0, "State Cmd:~p\n", [{call, ?MODULE, register_name,
                           [{RegName, SGroupName, Pid}]}]),
    Model = S#state.model,
    #model{groups=Grps}=Model,
    case lists:keyfind(SGroupName, 1, Grps) of 
        {SGroupName, NodeIds, NameSpace} -> 
            case lists:keyfind(RegName, 1, NameSpace) of 
                {RegName, _} ->
                    S;
                false ->
                    case lists:keyfind(Pid,2,NameSpace) of 
                        {_, Pid} -> 
                            S;
                        false ->
                            NewNameSpace= [{RegName, Pid}|
                                           lists:keydelete(RegName, 1, NameSpace)],
                            NewGrp={SGroupName,NodeIds, NewNameSpace},
                            NewGrps = lists:keyreplace(
                                        SGroupName, 1, Grps, NewGrp),
                            NewModel = Model#model{groups=NewGrps},
                            S#state{model=NewModel};
                        _ -> S
                    end
            end;
        false -> S
    end;
next_state(S, _V, {call, ?MODULE, whereis_name,  
                   [{TargetNode, _RegName, _SGroupName,
                     CurNode},_AllNodeIds]}) ->
    whereis_name_next_state(S, CurNode, TargetNode);

next_state(S, _V, {call, ?MODULE, send,  
                   [{_NodeId, _RegName, _SGroupName, _Msg,
                     _CurNode}, _AllNodeIds]}) ->
    S;
next_state(S, _V, _) ->
    S.

whereis_name_next_state(S, CurNode, TargetNode) ->
    #model{nodes=Nodes}=Model=S#state.model,
    {CurNode, CurConns, CurGrps} = lists:keyfind(CurNode, 1, Nodes),
    {TargetNode, _TargetConns, TargetGrps} = lists:keyfind(TargetNode, 1, Nodes),
    case lists:keyfind(TargetNode, 1, CurConns) of
        {TargetNode, _} -> S;  %% a connection exists.
        false ->
            case CurGrps == [free_normal_group] andalso
                TargetGrps == [free_normal_group] of
                true ->
                    %% both are free nodes, but not in the same group 
                    %% (otherwise should be connected already).
                    NewModel=merge_two_free_groups(Model, CurNode, TargetNode),
                    S#state{model=NewModel};
                false ->
                    %% all the other cases.
                    NewNodes=add_hidden_connections(Nodes, CurNode, TargetNode),
                    NewModel=Model#model{nodes=NewNodes},
                    S#state{model=NewModel}
            end
    end.

%%-------------------------------------------------------------%%
%%                                                             %%
%%                  General Properties                         %%
%%                                                             %%
%%-------------------------------------------------------------%%
prop_partition(S) ->
    #model{groups=Grps, free_groups = Fgs,
           free_hidden_groups=Fhgs,nodes=Nodes}=S#state.model,
    GrpNodes = sets:from_list(
                 lists:append(
                   [NodeIds||{_,NodeIds,_}<-Grps])),
    FreeNodes = sets:from_list(
                  lists:append(
                    [NodeIds||{NodeIds,_}<-Fgs])),
    FreeHiddenNodes=sets:from_list(
                      [NodeId||{NodeId, _NameSpace}<-Fhgs]),
    AllNodeIds = [NodeId||{NodeId, _, _}<-Nodes],
    Empty = sets:new(),
    Res=sets:intersection(GrpNodes, FreeNodes)==Empty andalso
        sets:intersection(GrpNodes, FreeHiddenNodes)==Empty andalso
        sets:intersection(FreeNodes, FreeHiddenNodes)==Empty andalso
        lists:sort(sets:to_list(sets:union([GrpNodes, FreeNodes, FreeHiddenNodes])))== 
        lists:sort(AllNodeIds),
    ?dbg(0, "partititon_prop:~p\n", [Res]),
    Res.

%% TO ADD:
%% Property about connections: if A is connected to B, then B should be connected to A too.
%% Namespace: no conficits in namespace.
%% The nodeids in a group should not be empty.
%%---------------------------------------------------------------
%%
%%  Adaptor functions.
%%---------------------------------------------------------------
register_name({RegName, SGroupName, Pid, Node}, AllNodes) ->
    Res=rpc:call(Node, s_group, register_name, 
                 [RegName,SGroupName, Pid]),
    State=fetch_node_states(AllNodes),
    {Res, State}.
    
re_register_name({RegName, SGroupName, Pid, Node}, AllNodes) ->
    Res=rpc:call(Node, s_group, re_register_name, 
                 [RegName,SGroupName, Pid]),
    State=fetch_node_states(AllNodes),
    {Res, State}.
  
whereis_name({NodeId, RegName, SGroupName, Node}, AllNodes)->
    Res=rpc:call(Node, s_group, whereis_name,
                 [NodeId, RegName, SGroupName]),
    State =fetch_node_states(AllNodes),
    {Res, State}.

send({NodeId, RegName, SGroupName, Msg, Node}, AllNodes)->
    Res=rpc:call(Node, s_group, send,
                 [NodeId, RegName, SGroupName, Msg]),
    State =fetch_node_states(AllNodes),
    {Res, State}.

%%---------------------------------------------------------------
%%
%%  translate real state to model state
%%---------------------------------------------------------------
fetch_node_states(_Nodes) ->
    NodeIds=[list_to_atom("node"++integer_to_list(N)++"@127.0.0.1")
             ||N<-lists:seq(1,14)],
    %% NodeIds = [NodeId||{NodeId, _, _}<-Nodes],
    %% this s_group info should also return pids.
    [{NodeId, rpc:call(NodeId, erlang, processes, []),
      rpc:call(NodeId, s_group, info, []),
      fetch_name_space(NodeId)}||NodeId<-NodeIds].

to_model(NodeIdStatePairs) ->
    ?dbg(0, "actual to abstract model.....\n",[]),
    GroupNodes0 =[case lists:keyfind(own_s_groups, 1, State) of
                     {own_s_groups, []}-> [];
                     {own_s_groups, List} -> List
                 end                          
                  ||{_NodeId, _, State, _NameSpace}<-NodeIdStatePairs, 
                   lists:member({state, synced}, State)],
    GroupNodes = sets:to_list(sets:from_list(lists:append(GroupNodes0))),
    Groups = analyze_group_nodes(GroupNodes),
    FreeNodes = [{NodeId, [NodeId|connections(NodeId)], 
                  NameSpace}
                 ||{NodeId, _Pids,State, NameSpace}<-NodeIdStatePairs, 
                   lists:member({own_s_groups, []}, State), 
                   publish_arg(NodeId) == normal],
    FreeGroups = analyze_free_nodes(FreeNodes),
    FreeHiddenGroups = [{NodeId, NameSpace}
                        ||{NodeId, _Pids, State, NameSpace}<-NodeIdStatePairs,
                          lists:member({own_s_groups, []}, State),
                          publish_arg(NodeId) == hidden],
    AllNodes=[{NodeId, connections(NodeId), group_names(State)}
           ||{NodeId, _, State, _NameSpace}<-NodeIdStatePairs],
    #model{groups = Groups,
           free_groups = FreeGroups,
           free_hidden_groups=FreeHiddenGroups,
           nodes=AllNodes}.
    
group_names(State) -> 
    case lists:keyfind(own_s_groups, 1, State) of 
        false -> [];
        {own_s_groups, OwnGrps} ->
            {GroupNames,_} =lists:unzip(OwnGrps),
            GroupNames
    end.
connections(NodeId) ->
    Visibles=rpc:call(NodeId, erlang, nodes, [visible]),
    Hiddens =rpc:call(NodeId, erlang, nodes, [hidden]),
    [{Id, visible}||Id<-Visibles] ++ 
        [{Id, hidden}||Id<-Hiddens].
        %% [{Id, hidden}||Id<-Hiddens--['eqc@127.0.0.1']].
                    
fetch_name_space(NodeId) ->
    NameSpace=rpc:call(NodeId,global, registered_names_with_pids, []),
    ?dbg(0,"NameSpace:~p\n", [NameSpace]),
    lists:sort(NameSpace).

publish_arg(NodeId) ->
    Res=case rpc:call(NodeId, init, get_argument, [hidden]) of 
            {ok,[[]]} ->
                hidden;
            {ok,[["true"]]} ->
                hidden;
            _ ->
	    normal
        end,
    Res.


analyze_free_nodes(FreeNodes)->
    FreeNodeIds = [NodeId||{NodeId, _Conns, _NameSpace}<-FreeNodes],
    NodeIdWithConnsAndNameSpace=
        [{NodeId, {FreeNodeIds--(FreeNodeIds--Conns), NameSpace}}||
            {NodeId, Conns, NameSpace}<-FreeNodes],
    %% need to take the connections into account!  
    FreeGroups= group_by(2, NodeIdWithConnsAndNameSpace),
    [{NodeIds, NameSpace}||{NodeIds, {_Conns, NameSpace}}<-FreeGroups].

%% This should be more strict!!!
analyze_group_nodes(GroupNameNodesPairs) ->
    F = fun(NodeIds, GrpName) ->
                NameSpace=[[{Name, Pid}||{Name, Grp, Pid}<-
                                             fetch_name_space(Id), Grp==GrpName]
                           || Id<-NodeIds],
                sets:to_list(sets:from_list(lists:append(NameSpace)))
        end,
    [{GroupName, Nodes,  F(Nodes, GroupName)}||{GroupName, Nodes}<-GroupNameNodesPairs].

is_the_same(State, AbstractState) ->
    ActualModel =normalise_model(to_model(State)),
    AbstractModel=normalise_model(AbstractState#state.model),
    ?dbg(0, "SameNodes:~p\n", [ActualModel#model.nodes==AbstractModel#model.nodes]),
    ?dbg(0, "SameSGroups:~p\n", [ActualModel#model.groups==AbstractModel#model.groups]),
    IsTheSame=(ActualModel==AbstractModel),
    ?dbg(10, "Is the same:~p\n", [IsTheSame]),
    IsTheSame.

normalise_model(Model) ->
    Groups = Model#model.groups,
    FreeGroups = Model#model.free_groups,
    FreeHiddenGroups = Model#model.free_hidden_groups,
    Nodes = Model#model.nodes,
    Groups1=lists:keysort(
              1, [{GrpName, lists:usort(NodeIds), 
                   lists:usort(NameSpace)}
                  ||{GrpName, NodeIds, NameSpace}<-Groups]),
    FreeGroups1 = lists:keysort(
                    1, [{lists:usort(Ids), lists:usort(NameSpace)}
                        ||{Ids, NameSpace}<-FreeGroups]),
    FreeHiddenGroups1 = lists:keysort(
                          1,[{Id, lists:usort(NameSpace)}
                             ||{Id, NameSpace}<-FreeHiddenGroups]),
    Nodes1 = lists:keysort(
               1, [{Id, lists:usort(Conns), lists:usort(GrpNames)}
                   ||{Id, Conns, GrpNames}<-Nodes]),
    #model{groups = Groups1, 
           free_groups = FreeGroups1,
           free_hidden_groups = FreeHiddenGroups1,
           nodes = Nodes1}.
           
                         
%%---------------------------------------------------------------
%%
%% Generators.
%%---------------------------------------------------------------
%% How to solve the dependency between parameters?
gen_register_name_pars(_S=#state{ref=Ref, model=Model}) ->
    Grps=Model#model.groups,
    if Grps==[] orelse Ref==[] ->
           {undefined, undefined, undefined, undefined};
       true ->
            ?LET({GrpName, NodeIds, _Namespace}, eqc_gen:oneof(Grps),
                 ?LET(NodeId, eqc_gen:oneof(NodeIds),
                      ?LET(Name, gen_reg_name(),
                           {list_to_atom(Name),GrpName, 
                            oneof(element(2, lists:keyfind(NodeId, 1, Ref))),
                            NodeId})))
    end.


gen_re_register_name_pars(_S=#state{ref=Ref, model=Model}) ->
    Grps=Model#model.groups,
    if Grps==[] orelse Ref==[] ->
            {undefined, undefined, undefined, undefined};
       true ->
            ?LET({GrpName, NodeIds, Namespace}, eqc_gen:oneof(Grps),
                 ?LET(NodeId, eqc_gen:oneof(NodeIds),
                      ?LET(Name, gen_reg_name(Namespace),
                           {list_to_atom(Name),GrpName, 
                            oneof(element(2, lists:keyfind(NodeId, 1, Ref))),
                            NodeId})))
    end.

gen_whereis_name_pars(_S=#state{model=Model}) ->
    Grps=Model#model.groups,
    FreeGrps = [{free_normal_group, Ids, NS}||
                   {Ids, NS}<-Model#model.free_groups],
    HiddenGrps=[{free_hidden_group, [Id], NS}||
                   {Id, NS}<-Model#model.free_hidden_groups],
    AllGrps = Grps++FreeGrps++HiddenGrps,
    ?LET({GrpName, NodeIds, NameSpace},
         eqc_gen:oneof(AllGrps),
         {eqc_gen:oneof(NodeIds), 
          eqc_gen:oneof(element(1,lists:unzip(NameSpace))),
          GrpName}).

gen_send_pars(_S=#state{ref=_Ref, model=Model}) ->
    Grps=Model#model.groups,
    FreeGrps = [{free_normal_group, Ids, NS}||
                   {Ids, NS}<-Model#model.free_groups],
    HiddenGrps=[{free_hidden_group, [Id], NS}||
                   {Id, NS}<-Model#model.free_hidden_groups],
    AllGrps = Grps++FreeGrps++HiddenGrps,
    ?LET({GrpName, NodeIds, NameSpace},
         eqc_gen:oneof(AllGrps),
         {eqc_gen:oneof(NodeIds),
          eqc_gen:oneof(element(1,lists:unzip(NameSpace))),
          GrpName, gen_message()}).

gen_reg_name()->
    eqc_gen:non_empty(eqc_gen:list(eqc_gen:choose(97, 122))).
   
gen_reg_name(NameSpace) ->
    {UsedNames,_} = lists:unzip(NameSpace),
    NameCandidates=[atom_to_list(N)||N<-UsedNames]++
        ["aa", "bb", "cc", "dd", "ee", "ff"],
    eqc_gen:oneof(NameCandidates).


gen_message() ->
    eqc_gen:binary().
%%---------------------------------------------------------------
%%
%%   Utility functions.
%%
%%--------------------------------------------------------------
%% start and shutdown nodes...
setup()->
    ?dbg(1, "starting nodes ...\n", []),
    Cmd="c:/erl5.9.1/bin/erl ", 
    Str =" -detached -setcookie \"secret\" -config s_group.config",
    os:cmd(Cmd++" -name node1@127.0.0.1"++Str),
    os:cmd(Cmd++" -name node2@127.0.0.1"++Str),
    os:cmd(Cmd++" -name node3@127.0.0.1"++Str),
    os:cmd(Cmd++" -name node4@127.0.0.1"++Str),
    os:cmd(Cmd++" -name node5@127.0.0.1"++Str),
    os:cmd(Cmd++" -name node6@127.0.0.1"++Str),
    os:cmd(Cmd++" -name node7@127.0.0.1"++Str),
    os:cmd(Cmd++" -name node8@127.0.0.1"++Str),
    os:cmd(Cmd++" -name node9@127.0.0.1 -hidden "++Str),
    os:cmd(Cmd++" -name node10@127.0.0.1 -hidden "++Str),
    os:cmd(Cmd++" -name node11@127.0.0.1"++Str),
    os:cmd(Cmd++" -name node12@127.0.0.1"++Str),
    os:cmd(Cmd++" -name node13@127.0.0.1"++Str),
    os:cmd(Cmd++" -name node14@127.0.0.1"++Str),
    io:format("ddd\n"),
    timer:sleep(2000).
   
            
teardown()->
   F=fun(N) ->
              Node=list_to_atom("node"++integer_to_list(N)++"@127.0.0.1"),
              rpc:call(Node, erlang, halt, [])
      end,
    lists:foreach(fun(N) -> F(N) end, lists:seq(1, 14)).
   

all_node_ids(S) ->
    [NodeId||{NodeId, _, _}<-S#state.model#model.nodes].

add_hidden_connections(Nodes, Node1, Node2) ->
    {Node1, Conns1, Grps1} = lists:keyfind(Node1,1, Nodes),
    {Node2, Conns2, Grps2} = lists:keyfind(Node2,1, Nodes),
    NewConns1 = [{Node2, hidden}|Conns1],
    NewConns2 = [{Node1, hidden}|Conns2],
    lists:keyreplace(Node2, 1, 
                     lists:keyreplace(Node1, 1, Nodes, 
                                      {Node1, NewConns1, Grps1}),
                     {Node2, NewConns2, Grps2}).

merge_two_free_groups(Model=#model{free_groups=FreeGrps, nodes=Nodes}, 
                      Node1, Node2) ->
    [FreeGrp1={NodeIds1, NameSpace1}] =
        [{NodeIds, NameSpace}||{NodeIds, NameSpace}<-FreeGrps, 
                               lists:member(Node1, NodeIds)],
    [FreeGrp2={NodeIds2, NameSpace2}] =
        [{NodeIds, NameSpace}||{NodeIds, NameSpace}<-FreeGrps, 
                               lists:member(Node2, NodeIds)],
    OtherGrps = FreeGrps -- [FreeGrp1, FreeGrp2],
    %%NOTE: WE ASSUME THAT THIS IN NO NAME CONFLICTION.
    NewFreeGrp ={NodeIds1++NodeIds2, NameSpace1++NameSpace2}, 
    NewFreeGrps=[NewFreeGrp|OtherGrps],
    NewNodes = add_visible_connections(Nodes, NodeIds1, NodeIds2),
    Model#model{free_groups=NewFreeGrps, nodes=NewNodes}.
    

add_visible_connections(AllNodes, NodeIds1, NodeIds2) ->
    F = fun(Node={NodeId, Conns, GrpNames}) ->
                case lists:member(NodeId, NodeIds1) of 
                    true ->
                        Conns1=[{Id, visible}||Id<-NodeIds2],
                        {NodeId, Conns1++Conns, GrpNames};
                    false ->
                        case lists:memebr(NodeId, NodeIds2) of 
                            true ->
                                Conns2=[{Id, visible}||Id<-NodeIds1],
                                {NodeId, Conns2++Conns, GrpNames};
                            false -> Node
                        end
                end
        end,                                    
    [F(Node)||Node<-AllNodes].
    
find_name(Model, NodeId, GroupName, RegName) ->
    Nodes = Model#model.nodes,
    {NodeId, _, Grps} = lists:keyfind(NodeId,1,Nodes),
    [NameSpace]=case Grps of 
                    [free_hidden_group] ->
                        FreeHiddenGrps=Model#model.free_hidden_groups,
                        [NS||{Id, NS}<-FreeHiddenGrps, Id==NodeId];
                    [free_normal_group] ->
                        FreeGrps = Model#model.free_groups,
                        [NS||{Ids, NS}<-FreeGrps, lists:member(NodeId, Ids)];
                    _ ->
                        Grps = Model#model.groups,
                        [NS||{GrpName, _Ids, NS}<-Grps, GrpName==GroupName]
                end,
    case lists:keyfind(RegName, 1, NameSpace) of 
        {RegName, Pid} -> Pid;  %% Note: this pid may not have the node info!
        _ -> undefined
    end.
    


%%---------------------------------------------------------------%%
%%                                                               %%
%%   Miscellaneous functions.                                    %%
%%                                                               %%
%%---------------------------------------------------------------%%

-spec group_by(integer(), [tuple()]) -> [[tuple()]].
group_by(N, TupleList) ->
    SortedTupleList = lists:keysort(N, lists:usort(TupleList)),
    group_by(N, SortedTupleList, []).

group_by(_N,[],Acc) -> Acc;
group_by(N,TupleList = [T| _Ts],Acc) ->
    E = element(N,T),
    {TupleList1,TupleList2} = 
	lists:partition(fun (T1) ->
				element(N,T1) == E
			end,
			TupleList),
    {Es,_} = lists:unzip(TupleList1),
    group_by(N,TupleList2,Acc ++ [{Es, E}]).


proc_is_alive(Node, Pid) ->
    rpc:call(Node, erlang, process_info, [Pid])/=undefined.


%%---------------------------------------------------------------%%
%%                                                               %%
%%                        Notes                                  %%
%%                                                               %%
%%---------------------------------------------------------------%%

%% The command for starting testing:
%% eqc:quickcheck(s_group_eqc:prop_s_group()). 

%% Register_name returns 'yes' when registering a non-existent processes. 
%%
%% All the ests are executted sequentially; concurrrent execution of 
%% commands are not testeds.



%% Have a process when a process died during the testing. 
%% TODO: check how the test model update its own pids list.
