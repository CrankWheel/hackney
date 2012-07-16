%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2012 Benoît Chesneau <benoitc@e-engura.org>

%% @doc pool of sockets connections
%%
-module(hackney_pool).
-behaviour(gen_server).


-export([start_link/0, start_link/1]).
-export([socket/2, release/3,
         pool_size/1, pool_size/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-record(state, {
        pool_size,
        timeout,
        connections = dict:new(),
        sockets = dict:new()}).


socket(PidOrName, {Transport, Host0, Port}) ->
    Host = string:to_lower(Host0),
    Pid = self(),
    gen_server:call(PidOrName, {socket, {Transport, Host, Port}, Pid}).

release(PidOrName, {Transport, Host0, Port}, Socket) ->
    Host = string:to_lower(Host0),
    gen_server:call(PidOrName, {release, {Transport, Host, Port}, Socket}).


pool_size(PidOrName) ->
    gen_server:call(PidOrName, pool_size).

pool_size(PidOrName, {Transport, Host0, Port}) ->
    Host = string:to_lower(Host0),
    gen_server:call(PidOrName, {pool_size, {Transport, Host, Port}}).

start_link() ->
    start_link([]).

start_link(Options0) ->
    Options = maybe_apply_defaults([pool_size, timeout], Options0),
    case proplists:get_value(name, Options) of
        undefined ->
            gen_server:start_link(?MODULE, Options, []);
        Name ->
            gen_server:start_link({local, Name}, ?MODULE, Options, [])
    end.

init(Options) ->
    PoolSize = proplists:get_value(pool_size, Options),
    Timeout = proplists:get_value(timeout, Options),
    {ok, #state{pool_size=PoolSize, timeout=Timeout}}.


handle_call({socket, Key, Pid}, _From, State) ->
    {Reply, NewState} = find_connection(Key, Pid, State),
    {reply, Reply, NewState};
handle_call({release, Key, Socket}, _From, State) ->
    NewState = store_connection(Key, Socket, State),
    {reply, ok, NewState};
handle_call(pool_size, _From, #state{sockets=Sockets}=State) ->
    {ok, dict:size(Sockets), State};
handle_call({pool_size, Key}, _From, #state{connections=Conns}=State) ->
    Size = case dict:find(Key, Conns) of
        {ok, Sockets} ->
            length(Sockets);
        error ->
            0
    end,
    {ok, Size, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({timeout, Socket}, State) ->
    {noreply, remove_socket(Socket, State)};
handle_info({tcp_closed, Socket}, State) ->
    {noreply, remove_socket(Socket, State)};
handle_info({ssl_closed, Socket}, State) ->
    {noreply, remove_socket(Socket, State)};
handle_info({tcp_error, Socket, _}, State) ->
    {noreply, remove_socket(Socket, State)};
handle_info({ssl_error, Socket, _}, State) ->
    {noreply, remove_socket(Socket, State)};
handle_info({tcp, Socket, _}, State) ->
    {noreply, remove_socket(Socket, State)};
handle_info({ssl, Socket, _}, State) ->
    {noreply, remove_socket(Socket, State)};
handle_info(_, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
   {ok, State}.

terminate(_Reason, #state{sockets=Sockets}) ->
    lists:foreach(fun(Socket, {{Transport, _, _}, Timer}) ->
                cancel_timer(Socket, Timer),
                Transport:close(Socket)
        end, dict:to_list(Sockets)),
    ok.

%% internals

find_connection({Transport, _Host, _Port}=Key, Pid,
                #state{connections=Conns, sockets=Sockets}=State) ->
    case dict:find(Key, Conns) of
        {ok, [S | Rest]} ->
            Transport:setopts(S, [{active, false}]),
            case Transport:controlling_process(S, Pid) of
                ok ->
                    {_, Timer} = dict:fetch(S, Sockets),
                    cancel_timer(S, Timer),
                    NewConns = update_connections(Rest, Key, Conns),
                    NewSockets = dict:erase(S, Sockets),
                    NewState = State#state{connections=NewConns,
                                           sockets=NewSockets},
                    {{ok, S}, NewState};
                {error, badarg} ->
                    Transport:setopts(S, [{active, once}]),
                    {no_socket, State};
                _ ->
                    find_connection(Key, Pid, remove_socket(S, State))
            end;
        error ->
            {no_socket, State}
    end.

remove_socket(Socket, #state{connections=Conns, sockets=Sockets}=State) ->
    case dict:find(Socket, Sockets) of
        {Key, Timer} ->
            cancel_timer(Socket, Timer),
            ConnSockets = lists:delete(Socket, dict:fetch(Key, Conns)),
            NewConns = update_connections(ConnSockets, Key, Conns),
            NewSockets = dict:erase(Socket, Sockets),
            State#state{connections=NewConns, sockets=NewSockets};
        false ->
            State
    end.


store_connection({Transport, _, _} = Key, Socket,
                 #state{timeout=Timeout, connections=Conns,
                        sockets=Sockets}=State) ->
    Timer = erlang:send_after(Timeout, self(), {timeout, Socket}),
    Transport:setopts(Socket, [{active, once}]),
    ConnSockets = case dict:find(Key, Conns) of
        {ok, OldSockets} ->
            [Socket | OldSockets];
        error -> [Socket]
    end,

    State#state{connections = dict:store(Key, ConnSockets, Conns),
                sockets = dict:store(Socket, {Key, Timer}, Sockets)}.


update_connections([], Key, Connections) ->
    dict:erase(Key, Connections);
update_connections(Sockets, Key, Connections) ->
    dict:store(Key, Sockets, Connections).


maybe_apply_defaults([], Options) ->
    Options;
maybe_apply_defaults([OptName | Rest], Options) ->
    case proplists:is_defined(OptName, Options) of
        true ->
            maybe_apply_defaults(Rest, Options);
        false ->
            {ok, Default} = application:get_env(hackney, OptName),
            maybe_apply_defaults(Rest, [{OptName, Default} | Options])
    end.


cancel_timer(Socket, Timer) ->
    case erlang:cancel_timer(Timer) of
        false ->
            receive
                {timeout, Socket} -> ok
            after
                0 -> ok
            end;
        _ -> ok
    end.
