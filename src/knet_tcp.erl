%%
%%   Copyright 2012 Dmitry Kolesnikov, All Rights Reserved
%%   Copyright 2012 Mario Cardona, All Rights Reserved
%%
%%   Licensed under the Apache License, Version 2.0 (the "License");
%%   you may not use this file except in compliance with the License.
%%   You may obtain a copy of the License at
%%
%%       http://www.apache.org/licenses/LICENSE-2.0
%%
%%   Unless required by applicable law or agreed to in writing, software
%%   distributed under the License is distributed on an "AS IS" BASIS,
%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%   See the License for the specific language governing permissions and
%%   limitations under the License.
%%
%%   @description
%%      tcp/ip client/server konduit  
%%
-module(knet_tcp).
-author('Dmitry Kolesnikov <dmkolesnikov@gmail.com>').
-author('Mario Cardona <marioxcardona@gmail.com>').

-behaviour(konduit).

-export([init/1, free/2, ioctl/2]).
-export(['IDLE'/2, 'LISTEN'/2, 'CONNECT'/2, 'ACCEPT'/2, 'ESTABLISHED'/2]).

%% internal state
-record(fsm, {
   role  :: client | server,
   
   tconn,  % time to connect
   tpckt,  % packet arrival time 

   inet,   % inet family
   sock,   % tcp/ip socket
   peer,   % peer address  
   addr,   % local address
   opts    % connection option
}). 

%%
-define(SOCK_OPTS, [
   {active, once}, 
   {mode, binary}, 
   {nodelay, true},
   {recbuf, 16 * 1024},
   {sndbuf, 16 * 1024}
]).

%
-define(T_CONNECT,     20000).  %% tcp/ip connection timeout

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

%%
%%
init([Inet, {{listen, _Opts}, _Peer}=Msg]) ->
   {ok, 'LISTEN', init(Inet, Msg)}; 

init([Inet, {{accept, _Opts}, _Peer}=Msg]) ->
   {ok, 'ACCEPT', init(Inet, Msg), 0};

init([Inet, {{connect, _Opts}, _Peer}=Msg]) ->
   {ok, 'CONNECT', init(Inet, Msg), 0};

init([Inet]) ->
   {ok, 'IDLE', Inet}.

%%
%%
free(Reason, S) ->
   case erlang:port_info(S#fsm.sock) of
      undefined -> 
         % socket is not active
         ok;
      _ ->
         lager:info("tcp/ip terminated ~p, reason ~p", [S#fsm.peer, Reason]),
         gen_tcp:close(S#fsm.sock)
   end.

%%
%%  
ioctl(socket, #fsm{sock=Sock}) ->
   Sock;
ioctl(latency, #fsm{tconn=Tconn, tpckt=Tpckt}) ->
   [
      {tcp,  Tconn},
      {pckt, knet_cnt:val(Tpckt)},
      {pcnt, knet_cnt:count(Tpckt)}
   ];
ioctl(_, _) ->
   undefined.

%%%------------------------------------------------------------------
%%%
%%% IDLE: allows to chain TCP/IP konduit
%%%
%%%------------------------------------------------------------------
'IDLE'({{accept,  _Opts}, _Peer}=Msg, #fsm{inet=Inet}) ->
   {next_state, 'ACCEPT', init(Inet, Msg), 0};
'IDLE'({{connect, _Opts}, _Peer}=Msg, #fsm{inet=Inet}) ->
   {next_state, 'CONNECT', init(Inet, Msg), 0}.

%%%------------------------------------------------------------------
%%%
%%% LISTEN: holder of listen socket
%%%
%%%------------------------------------------------------------------
'LISTEN'({ctrl, Ctrl}, S) ->
   {Val, NS} = ioctrl(Ctrl, S),
   {reply, Val, 'LISTEN', NS}.

%%%------------------------------------------------------------------
%%%
%%% CONNECT
%%%
%%%------------------------------------------------------------------
'CONNECT'(timeout, #fsm{peer={Host, Port}, opts=Opts} = S) ->
   % socket connect timeout
   T  = proplists:get_value(timeout, S#fsm.opts, ?T_CONNECT),    
   % TODO: overwrite default sock opts with user 
   T1 = erlang:now(),
   case gen_tcp:connect(check_host(Host), Port, ?SOCK_OPTS ++ Opts, T) of
      {ok, Sock} ->
         {ok, Peer} = inet:peername(Sock),
         {ok, Addr} = inet:sockname(Sock),
         Tconn = timer:now_diff(erlang:now(), T1),
         lager:info("tcp/ip connected ~p, local addr ~p in ~p usec", [Peer, Addr, Tconn]),
         pns:register(knet, {iid(S#fsm.inet), established, Addr, Peer}, self()),
         {emit, 
            {tcp, Peer, established},
            'ESTABLISHED', 
            S#fsm{
               role   = client,
               sock   = Sock,
               addr   = Addr,
               peer   = Peer,
               tconn  = Tconn,
               tpckt  = knet_cnt:new(time)
            }
         };
      {error, Reason} ->
         lager:error("tcp/ip connect ~p, error ~p", [{Host, Port}, Reason]),
         {emit,
            {tcp, {Host, Port}, {error, Reason}},
            'IDLE',
            S
         }
   end.
   

%%%------------------------------------------------------------------
%%%
%%% ACCEPT
%%%
%%%------------------------------------------------------------------
'ACCEPT'(timeout, #fsm{sock = LSock} = S) ->
   % accept a socket
   {ok, Sock} = gen_tcp:accept(LSock),
   {ok, Peer} = inet:peername(Sock),
   {ok, Addr} = inet:sockname(Sock),
   lager:info("tcp/ip accepted ~p, local addr ~p", [Peer, Addr]),
   pns:register(knet, {iid(S#fsm.inet), established, Peer}, self()),
   {emit, 
      {tcp, Peer, established},
      'ESTABLISHED', 
      S#fsm{
         sock  = Sock,
         addr  = Addr,
         peer  = Peer,
         tconn = 0,
         tpckt = knet_cnt:new(time)
      } 
   }.
   
%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------
'ESTABLISHED'({ctrl, Ctrl}, S) ->
   {Val, NS} = ioctrl(Ctrl, S),
   {reply, Val, 'ESTABLISHED', NS};
   
'ESTABLISHED'({tcp_error, _, Reason}, #fsm{peer=Peer}=S) ->
   lager:error("tcp/ip error ~p, peer ~p", [Reason, Peer]),
   {emit,
      {tcp, Peer, {error, Reason}},
      'IDLE',
      S
   };
   
'ESTABLISHED'({tcp_closed, _}, #fsm{peer=Peer}=S) ->
   lager:info("tcp/ip terminated by peer ~p", [Peer]),
   {emit,
      {tcp, Peer, terminated},
      'IDLE',
      S
   };

'ESTABLISHED'({tcp, _, Data}, #fsm{peer=Peer, tpckt=Tpckt}=S) ->
   lager:debug("tcp/ip recv ~p~n~p~n", [Peer, Data]),
   % TODO: flexible flow control
   inet:setopts(S#fsm.sock, [{active, once}]),
   {emit, 
      {tcp, Peer, {recv, Data}},
      'ESTABLISHED',
      S#fsm{tpckt=knet_cnt:add(now, Tpckt)}
   };
   
'ESTABLISHED'({send, _Peer, Data}, #fsm{peer=Peer}=S) ->
   lager:debug("tcp/ip send ~p~n~p~n", [Peer, Data]),
   case gen_tcp:send(S#fsm.sock, Data) of
      ok ->
         {next_state, 'ESTABLISHED', S};
      {error, Reason} ->
         lager:error("tcp/ip error ~p, peer ~p", [Reason, Peer]),
         {reply,
            {tcp, Peer, {error, Reason}},
            'IDLE',
            S
         }
   end;
   
'ESTABLISHED'({terminate, _Peer}, #fsm{sock=Sock, peer=Peer}=S) ->
   lager:info("tcp/ip terminated to peer ~p", [Peer]),
   gen_tcp:close(Sock),
   {reply,
      {tcp, Peer, terminated},
      'IDLE',
      S
   }.   
   
   
%%%------------------------------------------------------------------
%%%
%%% Private
%%%
%%%------------------------------------------------------------------

%%
%% initializes konduit
init(Inet, {{listen, Opts}, Addr}) when is_integer(Addr) ->
   init(Inet, {{listen, Opts}, {any, Addr}}); 
init(Inet, {{listen, Opts}, Addr}) ->
   % start tcp/ip listener
   {IP, Port}  = Addr,
   {ok, LSock} = gen_tcp:listen(Port, [
      Inet, 
      {ip, IP}, 
      {reuseaddr, true} | ?SOCK_OPTS
   ]),
   pns:register(knet, {iid(Inet), listen, Addr}, self()),
   lager:info("tcp/ip listen on ~p", [Addr]),
   #fsm{
      role = server,
      inet = Inet,
      sock = LSock,
      addr = Addr,
      opts = Opts
   };

init(Inet, {{accept, Opts}, Addr}) when is_integer(Addr) ->
   init(Inet, {{accept, Opts}, {any, Addr}}); 
init(Inet, {{accept, Opts}, Addr}) ->
   % start tcp/ip acceptor
   LPid = pns:whereis(knet, {iid(Inet), listen, Addr}),
   {ok, LSock} = konduit:ioctl(socket, LPid), %% TODO: FIXME
   lager:info("tcp/ip accepting ~p (~p)", [Addr, LSock]),
   #fsm{
      role = server,
      inet = Inet,
      sock = LSock,
      addr = Addr,
      opts = Opts
   };

init(Inet, {{connect, Opts}, Peer}) ->
   % start tcp/ip client
   #fsm{
      role = client,
      inet = Inet,
      peer = Peer,
      opts = Opts
   }.


%%
%% 
iid(inet)  -> tcp4;
iid(inet6) -> tcp6. 

%%
%% 
check_host(Host) when is_binary(Host) ->
   binary_to_list(Host);
check_host(Host) ->
   Host.   

%%%------------------------------------------------------------------   
%%%
%%% ctrl
%%%
%%%------------------------------------------------------------------

%%
%% konduit ioctrl
ioctrl(address, S) ->
   {{S#fsm.addr, S#fsm.peer}, S};

ioctrl(socket, S) ->
   {S#fsm.sock, S};

ioctrl(_, S) ->
   {nil, S}.
   
