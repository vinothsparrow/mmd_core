-module(services).
-include_lib("p6core/include/p6core.hrl").
-include("mmd.hrl").
-include_lib("p6core/include/dmap.hrl").

-compile([export_all]).

-define(SERVER, ?MODULE).
-define(WATCHERS,service_watchers).
-define(P6DMAP,service_map).

-record(state, {known=sets:new(), chans=channel_mgr:new()}).

xformEntryAdd(E=#dm{val={SL,HL},node=Node}) ->
    W = service_node_weight:getNodeWeight(Node),
    E#dm{val={W,SL,HL}};
xformEntryAdd(E=#dm{val={_,SL,HL},node=Node}) ->
    W = service_node_weight:getNodeWeight(Node),
    E#dm{val={W,SL,HL}};
xformEntryAdd(E) -> E.

transformValues(MFA) ->
    p6dmap:xformValues(?P6DMAP,MFA).

regUnique(Name,SortKey) -> regUnique(self(),Name,SortKey).
regUnique(Pid,Name,SortKey) ->
    case p6dmap:addGlobal(?P6DMAP,Pid,p6str:mkatom(Name),SortKey) of
        ok ->  ?linfo("Registered unique global: ~p (~p) with key: ~p",[Name,Pid,SortKey]),
               ok;
        Other -> ?linfo("Failed to register global service ~p (~p) with key: ~p -- ~p",[Name,Pid,SortKey,Other]),
                 Other
    end.

regGlobal(Names) when is_list(Names) -> lists:foreach(fun(N)->regGlobal(N) end, Names);
regGlobal(Name) -> regGlobal(Name,0).
regGlobal(Name,Load) -> regGlobal(self(),Name,Load).
regGlobal(Pid,Name,Load) ->
    case p6dmap:addGlobal(?P6DMAP,Pid,p6str:mkatom(Name),{Load,cpu_load:util()}) of
        ok -> ?linfo("Registered global: ~p (~p)",[Name,Pid]),
              ok;
        Other -> ?linfo("Failed to register global service ~p (~p,~p) : ~p",[Name,Pid,Load,Other]),
                 Other
    end.

regLocal(Names) when is_list(Names) -> lists:foreach(fun(Name) -> ok = regLocal(Name) end, Names);
regLocal(Name) ->
    case p6dmap:addLocal(?P6DMAP,self(),p6str:mkatom(Name),local) of
        ok -> ?linfo("Registered local: ~p (~p)",[Name,self()]), ok;
        Other -> ?linfo("Failed to register global service ~p (~p) : ~p",[Name,self(),Other]),
                 Other
    end.

unregGlobal(Pid, Name) ->
    case p6dmap:delGlobal(?P6DMAP, Pid, p6str:mkatom(Name)) of
	ok ->
	    ?linfo("Unregistered global ~p (~p)", [Name, Pid]),
	    ok;
	Other -> ?linfo("Failed to unregister global service ~p (~p): ~p",
			[Name, Pid, Other]),
		 Other
    end.

updateSvcLoad(Name,SvcLoad) -> updateSvcLoad(self(),Name,SvcLoad).
updateSvcLoad(Pid,Name,SvcLoad) -> updateLoad(Pid,Name,{SvcLoad,cpu_load:util()}).

updateLoad(Name,Load) -> updateLoad(self(),Name,Load).
updateLoad(Pid,Name,Load={_,_}) -> p6dmap:set(?P6DMAP,Pid,p6str:mkatom(Name),Load).

getDM() -> whereis(?P6DMAP).

allServiceNames() -> p6dmap:uniqueKeys(?P6DMAP).

ourServices() ->
    p6dmap:getOurEntries(?P6DMAP).

ourGlobalServices() -> p6dmap:getOurEntries(?P6DMAP,g).
ourLocalServices() -> p6dmap:getOurEntries(?P6DMAP,l).
service2Nodes() ->
    dict:to_list(lists:foldl(fun([S,N],Dict) -> dict:append(S,N,Dict) end, dict:new(), p6dmap:keyToNodes(?P6DMAP))).

%% Returns list of DM,Pid,Val
find(Name) when is_binary(Name) ->
    try binary_to_existing_atom(Name,utf8) of
	    Atom -> find(Atom)
    catch
        Type:Reason -> ?lwarn("Failed to convert: ~p in to existing atom {~p,~p}",[Name,Type,Reason]), []
    end;
find(Name) -> p6dmap:getWithDM(?P6DMAP,p6str:mkatom(Name)).

findBalanced(Name) ->
    case find(Name) of
        [] -> [];
        [A] -> [A];
        List -> balance(List)
    end.

regProxy({T,Mod},Names) when is_list(Names) ->
    regProxy(Mod,lists:map(fun(R={_,_}) -> R;
                              (N) -> {T,N} end,
                           Names));
regProxy(Mod,Names) when is_list(Names) -> mmd_mod_proxy_sup:createProxy(Mod,Names);
regProxy(Mod,Name) -> regProxy(Mod,[Name]).
regProxy({Mod,Name}) -> regProxy(Mod,Name);
regProxy(Mod) -> regProxy(Mod,[Mod]).

registerConfigured() ->
    case application:get_env(services) of
        undefined -> ok;
        {ok,List} -> lists:foreach(fun(I)-> regProxy(I) end, List)
    end.


init([]) ->
    p6dmap:new(?P6DMAP,?MODULE),
    regLocal(?MODULE),
    registerConfigured(),
    timer:send_interval(500, update_svcs),
    {ok, #state{}}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


%% Channel Messages

handle_info(update_svcs, State) ->
    All = dispatchDiff(State),
    {noreply,State#state{known=All}};

handle_info(Info, State) ->
    ?linfo("Unexpected info: ~p, with state: ~p",[Info,State]),
    {noreply, State}.



handle_call({mmd, From, CC=#channel_create{type=call,body=?raw(<<"N">>)}}, _From, State) ->
    mmd_msg:reply(From, CC, allServiceNames()),
    {reply, ok, State};

handle_call({mmd, From, CC=#channel_create{type=call,body=undefined}}, _From, State) ->
    mmd_msg:reply(From, CC, allServiceNames()),
    {reply, ok, State};

handle_call({mmd, From, CC=#channel_create{type=call,body=SvcPattern}}, _From, State) ->
    Str = case mmd_decode:decode(SvcPattern) of
	      {S, _Rst} -> S;
	      S -> S
	  end,
    case re:compile(Str) of
	{ok, MP} ->
	    Ret = lists:foldl(fun(Svc,Acc) ->
				      SB = p6str:mkbin(Svc),
				      case re:run(SB, MP) of
					  nomatch -> Acc;
					  _ -> [SB|Acc]
				      end
			      end,
			      [],
			      allServiceNames()),
	    mmd_msg:reply(From, CC, Ret);
	{error, {ErrString, Pos}} ->
	    mmd_msg:error(From, CC, ?INVALID_REQUEST,
			  "Failed to compile regex: reason: ~p, "
			  "pos: ~p, regex: ~p", [ErrString, Pos, SvcPattern])
    end,
    {reply,ok,State};

handle_call({mmd, From, CC=#channel_create{type=sub, body=SvcPattern}}, _From,
	    State=#state{chans=Chans}) ->
    case case mmd_decode:decode(SvcPattern) of
	     {nil, _Rst} -> re:compile("");
	     {Str, _Rst} -> re:compile(Str);
	     undefined -> re:compile("");
	     S -> re:compile(S)
	 end of
	{ok, MP} ->
	    case channel_mgr:processIn(Chans, From, CC, MP) of
		{NewChans, _Msg} ->
		    All = dispatchDiff(State),
		    Filtered =
			sets:fold(fun (Svc, Svcs) ->
					  case re:run(p6str:mkbin(Svc), MP) of
					      nomatch -> Svcs;
					      _ -> [Svc | Svcs]
					  end
				  end,
				  [],
				  All),
		    mmd_msg:reply(From, CC, ?map([{added, ?array(Filtered)}])),
		    {reply, ok, State#state{known=All, chans=NewChans}};
		NewChans ->
		    {reply, ok, State#state{chans=NewChans}}
	    end;
	{error, {ErrString, Pos}} ->
	    mmd_msg:error(From, CC, ?INVALID_REQUEST,
			  "Failed to compile regex: reason: ~p, "
			  "pos: ~p, regex: ~p", [ErrString, Pos, SvcPattern]),
	    {reply, ok, State}
    end;

handle_call({mmd, From, M=#channel_close{}}, _From,
	    State=#state{chans=Chans}) ->
    {NewChans, _Msg} = channel_mgr:processIn(Chans, From, M),
    {reply, ok, State#state{chans=NewChans}};

handle_call(Request, From, State) ->
    ?linfo("Unexpected call: ~p from: ~p, with state: ~p",[Request,From,State]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    ?linfo("Unexpected cast: ~p, with state: ~p",[Msg,State]),
    {noreply, State}.

re_filter(MP, Es) -> re_filter(MP, Es, []).
re_filter(_MP, [], Acc) -> Acc;
re_filter(MP, [E | Es], Acc) ->
    case re:run(p6str:mkbin(E), MP) of
	nomatch -> re_filter(MP, Es, Acc);
	_ -> re_filter(MP, Es, [E | Acc])
    end.

dispatchDiff(State=#state{chans=Chans}) ->
    {All, Add, Rm} = calcDiff(State),
    channel_mgr:send_all_matching(
      fun (MP) ->
	      case {re_filter(MP, Add), re_filter(MP, Rm)} of
		  {[], []} -> false;
		  {A, []} -> {true, ?map([{added, ?array(A)}])};
		  {[], R} -> {true, ?map([{removed, ?array(R)}])};
		  {A, R} -> ?map([{added, ?array(A)}, {removed,?array(R)}])
	      end
      end, Chans),
    All.

-spec(calcDiff(State::#state{}) -> {All::set, Added::list(), Removed::list()}).
calcDiff(#state{known=Known}) ->
    All = sets:from_list(services:allServiceNames()),
    {All,sets:to_list(sets:subtract(All,Known)),sets:to_list(sets:subtract(Known,All))}.


%% Initial version duplicates logic to boot strap, avoids having a magic value to compare
mapFree([Entry=[_,_,{DataCenter,0,HostLoad}]|Rest]) ->
    HostFree = 100 - HostLoad,
    mapFree(Rest,DataCenter,HostFree,[{HostFree,Entry}]);

%% Don't know what we're looking at, but it isn't something
%% we can do weighted random robin on.
mapFree(_Entries) ->
    fail.

mapFree([],_MinDataCenter,TotalFree,Acc) ->
    {TotalFree,Acc};

%%Ignore local nodes
%%mapFree([[_,_,{1,0,_HostLoad}]|Rest],MinDataCenter,TotalFree,Acc) ->
%%    mapFree(Rest,MinDataCenter,TotalFree,Acc);

mapFree([Entry=[_,_,{DataCenter,0,HostLoad}]|Rest],MinDataCenter,_TotalFree,_Acc) when DataCenter < MinDataCenter ->
%%    ?linfo("Better DC: ~p < ~p : ~p",[DataCenter,MinDataCenter,Entry]),
    HostFree = 100 - HostLoad,
    mapFree(Rest,DataCenter,HostFree,[{HostFree,Entry}]);

mapFree([Entry=[_,_,{DataCenter,0,HostLoad}]|Rest],MinDataCenter,TotalFree,Acc) when DataCenter == MinDataCenter ->
    HostFree = 100 - HostLoad,
    mapFree(Rest,DataCenter,TotalFree+HostFree,[{HostFree,Entry}|Acc]);

mapFree([_Entry=[_,_,{DataCenter,0,_HostLoad}]|Rest],MinDataCenter,TotalFree,Acc) when DataCenter > MinDataCenter ->
%%    ?linfo("Worse DC: ~p > ~p : ~p",[DataCenter,MinDataCenter,_Entry]),
    mapFree(Rest,MinDataCenter,TotalFree,Acc);

mapFree(_NoMatch,_MinDataCenter,_TotalFree,_Acc) ->
    ?ldebug("Fail: ~p",[_NoMatch]),
    fail.

balance(List) ->
    case mapFree(List) of
        fail -> lists:sort(fun([_,_,L1],[_,_,L2]) -> L1 < L2 end, List);
        {_Total,[{_,Entry}]} ->
            [Entry];
        {Total,Entries} ->
            Rand = random_service:uniform(trunc(Total)),
            E = walkUntil(Rand,Entries),
%%            ?ldebug("Balance of\nFree: ~p, Rand: ~p, Selected: ~p\nEntries: ~w",[Total,Rand,E,Entries]),
            [E]
    end.

walkUntil(_Num,[{_N,Entry}]) -> Entry;  % rand is trunc'd total, so may kenobi on us, this catches that
walkUntil(Num,[{N,Entry}|_Rest]) when N > Num -> Entry;
walkUntil(Num,[{N,_Entry}|Rest]) -> walkUntil(Num-N,Rest).



%% vim: ts=4:sts=4:sw=4:et:sta:
