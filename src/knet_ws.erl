%%
%%   Copyright (c) 2012 - 2013, Dmitry Kolesnikov
%%   Copyright (c) 2012 - 2013, Mario Cardona
%%   All Rights Reserved.
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
%% @description
%%   websocket protocol
-module(knet_ws).
-behaviour(pipe).

-include("knet.hrl").

-export([
   start_link/1, 
   start_link/2, 
   init/1, 
   free/2, 
   ioctl/2,
   'IDLE'/3, 
   'LISTEN'/3, 
   'CLIENT'/3,
   'SERVER'/3,
   'ESTABLISHED'/3
]).

%%
%% internal state
-record(fsm, {
   stream    = undefined :: #stream{}        % websocket data stream
  ,schema    = undefined :: atom()           % websocket transport schema (ws, wss)
  ,so        = undefined :: list() 
}).

%% web-socket magic number
-define(WS_GUID, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").
-define(VSN,     13).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

%%
%%
start_link(Opts) ->
   pipe:start_link(?MODULE, Opts ++ ?SO_HTTP, []).

start_link(Req, Opts) ->
   pipe:start_link(?MODULE, [Req, Opts], []).

%%
init([{_Mthd, Url, _Head, Env}, Opts]) ->
   %% protocol fsm is created by protocol upgrade
   {ok, 'ESTABLISHED',
      #fsm{
         stream  = ws_new(server, Url, Env, Opts)
      }
   };

init(SOpt) ->
   %% protocol fsm is created by knet
   {ok, 'IDLE', 
      #fsm{
         so = SOpt
      }
   }.

%%
free(_, _) ->
   ok.

%%
ioctl({upgrade, {_Mthd, _Uri, Head, _Env}=Req, SOpt}, undefined) ->
   %% web socket upgrade request
   <<"Upgrade">>   = pair:lookup('Connection', Head),
   <<"websocket">> = pair:lookup('Upgrade',    Head),
   Key  = pair:lookup(<<"Sec-Websocket-Key">>, Head),
   Hash = base64:encode(crypto:hash(sha, <<Key/binary, ?WS_GUID>>)),
   {Msg, _} = htstream:encode(
      {101
        ,[
            {'Upgrade',  <<"websocket">>}
           ,{'Connection', <<"Upgrade">>}
           ,{<<"Sec-WebSocket-Accept">>, Hash}
         ]
        ,<<>>
      },
      htstream:new()
   ),
   {Msg, {upgrade, ?MODULE, [Req, SOpt]}};

ioctl(_, _) ->
   throw(not_implemented).


%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

'IDLE'({listen,  Uri}, Pipe, State) ->
   pipe:b(Pipe, {listen, Uri}),
   {next_state, 'LISTEN', State};

'IDLE'({accept,  Uri}, Pipe, State) ->
   pipe:b(Pipe, {accept, Uri}),
   {next_state, 'SERVER', 
      State#fsm{
         schema = uri:schema(Uri),
         stream = ht_new(Uri, State#fsm.so)
      }
   };

'IDLE'({connect, Uri}, Pipe, State) ->
   % connect is compatibility wrapper for knet socket interface (translated to http GET request)
   % TODO: htstream support HTTP/1.2 (see http://www.jmarshall.com/easy/http/)
   pipe:b(Pipe, {connect, Uri}),
   Hash = base64:encode(crypto:hash(md5, scalar:s(random:uniform(16#ffff)))),
   Req  = {'GET', Uri, [
      {'Connection',      <<"Upgrade">>}
     ,{'Upgrade',       <<"websocket">>}
     ,{'Host',        uri:authority(Uri)}
     ,{<<"Sec-WebSocket-Key">>,     Hash}
     ,{<<"Sec-WebSocket-Version">>, ?VSN}
   ]},
  'CLIENT'(Req, Pipe, State#fsm{stream = ht_new(Uri, State#fsm.so)}).


%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'(_Msg, _Pipe, State) ->
   {next_state, 'LISTEN', State}.

%%%------------------------------------------------------------------
%%%
%%% SERVER
%%%
%%%------------------------------------------------------------------   

'SERVER'({Prot, _Sock, established}, _Pipe, State)
 when ?is_transport(Prot) ->
   {next_state, 'SERVER', State};

'SERVER'({Prot, _Sock, {terminated, _}}, _Pipe, State)
 when ?is_transport(Prot) ->
   {stop, normal, State};

%%
%% remote client request (handshake websocket)
'SERVER'({Prot, _Sock, Pckt}, Pipe, State)
 when ?is_transport(Prot), is_binary(Pckt) ->
   case ht_recv(Pckt, Pipe, State#fsm.stream) of
      {upgrade, Stream} ->
         {next_state, 'ESTABLISHED', State#fsm{stream=Stream}};
      {eof,     Stream} ->
         pipe:b(Pipe, {ws, self(), {terminated, normal}}),
         {stop, normal, State#fsm{stream=Stream}};
      {_,   Stream} ->
         {next_state, 'SERVER', State#fsm{stream=Stream}}
   end;

'SERVER'(_Msg, _Pipe, State) ->
   {next_state, 'SERVER', State}.

%%%------------------------------------------------------------------
%%%
%%% CLIENT
%%%
%%%------------------------------------------------------------------   


%%
%% protocol signaling
'CLIENT'({Prot, _Sock, {established, _Peer}}, _, State)
 when ?is_transport(Prot) ->
   {next_state, 'CLIENT', State};

'CLIENT'({Prot, _Sock, {terminated, Reason}}, Pipe, State)
 when ?is_transport(Prot) ->
   pipe:a(Pipe, {ws, self(), {terminated, Reason}}),
   {stop, normal, State};

%%
%% remote acceptor response
'CLIENT'({Prot, Sock, Pckt}, Pipe, #fsm{stream = Stream} = State)
 when ?is_transport(Prot), is_binary(Pckt) ->
   try
      case htstream:decode(Pckt, Stream#stream.recv) of
         {{101, Msg, Head}, Http} ->
            <<"Upgrade">>   = pair:lookup('Connection', Head),
            <<"websocket">> = pair:lookup('Upgrade',    Head),
            pipe:b(Pipe, {ws, self(), {101, Msg, Head, []}}),
            'ESTABLISHED'({Prot, Sock, htstream:buffer(Http)}, Pipe, 
               State#fsm{stream = ws_new(server, Stream#stream.peer, [])});
         {[], Http} ->
            {next_state, 'CLIENT', State#fsm{stream = Stream#stream{recv = Http}}}
      end
   catch _:Reason ->
      ?NOTICE("knet [ws]: failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      pipe:b(Pipe, {ws, self(), {terminated, Reason}}),
      {stop, Reason, State}
   end;

%%
%% local client request
'CLIENT'({Mthd, {uri, _, _}=Uri, Heads}, Pipe, State) ->
   'CLIENT'({Mthd, uri:path(Uri), Heads}, Pipe, State);

'CLIENT'(Msg, Pipe, #fsm{stream = Stream} = State) ->
   try
      {Pckt, Send} = htstream:encode(Msg, Stream#stream.send),
      pipe:b(Pipe, Pckt),
      {next_state, 'CLIENT', State#fsm{stream = Stream#stream{send = Send}}}
   catch _:Reason ->
      ?NOTICE("knet [ws]: failure ~p ~p", [Reason, erlang:get_stacktrace()]),
      pipe:b(Pipe, {ws, self(), {terminated, Reason}}),
      {stop, Reason, State}
   end.


%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------   

'ESTABLISHED'({Prot, _, {terminated, Reason}}, Pipe, State)
 when ?is_transport(Prot) ->
   pipe:b(Pipe, {ws, self(), {terminated, Reason}}),
   {stop, normal, State};

%%
%% remote peer packet
'ESTABLISHED'({Prot, _, Pckt}, Pipe, State)
 when ?is_transport(Prot), is_binary(Pckt) ->
   case ws_recv(Pckt, Pipe, State#fsm.stream) of
      {eof, Stream} ->
         pipe:b(Pipe, {ws, self(), {terminated, normal}}),
         {stop, normal, State#fsm{stream=Stream}};
      {_,   Stream} ->
         {next_state, 'ESTABLISHED', State#fsm{stream=Stream}}
   end;

%%
%% local peer message
'ESTABLISHED'(Msg, Pipe, State)
 when ?is_iolist(Msg) ->
   case ws_send(Msg, Pipe, State#fsm.stream) of
      {eof, Stream} ->
         {stop, normal, State#fsm{stream=Stream}};
      {_,   Stream} ->
         {next_state, 'ESTABLISHED', State#fsm{stream=Stream}}
   end;

'ESTABLISHED'(hibernate, Pipe, State) ->
   {next_state, 'ESTABLISHED', State}.

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%%
%% create new #stream{} 
ws_new(Type, Url, _SOpt) ->
   #stream{
      send = wsstream:new(Type)
     ,recv = wsstream:new(Type)
     ,peer = Url
   }.

ws_new(Type, Url, _Env, _SOpt) ->
   #stream{
      send = wsstream:new(Type)
     ,recv = wsstream:new(Type)
     ,peer = Url
     % ,peer = opts:val(peer, Env)
     % ,addr = uri:schema(ws, Url) %% (?)
     ,tss  = os:timestamp() 
   }.

%%
%% web socket recv message
ws_recv(Pckt, Pipe, #stream{}=Ws) ->
   ?DEBUG("knet [websock] ~p: recv ~p~n~p", [self(), Ws#stream.peer, Pckt]),
   {Msg, Recv} = wsstream:decode(Pckt, Ws#stream.recv),
   lists:foreach(fun(X) -> pipe:b(Pipe, {ws, self(), X}) end, Msg),
   {wsstream:state(Recv), Ws#stream{recv=Recv}}.

%%
%% web socket send message
ws_send(Msg, Pipe, #stream{}=Ws) ->
   ?DEBUG("knet [websock] ~p: send ~p~n~p", [self(), Ws#stream.peer, Msg]),
   {Pckt, Send} = wsstream:encode(Msg, Ws#stream.send),
   lists:foreach(fun(X) -> pipe:b(Pipe, X) end, Pckt),
   {wsstream:state(Send), Ws#stream{send=Send}}.

%%
%% create new http #stream{}
ht_new(Url, _SOpt) ->
   #stream{
      send = htstream:new()
     ,recv = htstream:new()
     ,peer = Url
   }.

ht_recv(Pckt, Pipe, #stream{}=Ht) ->
   ?DEBUG("knet [websock] ~p: recv ~p~n~p", [self(), Ht#stream.peer, Pckt]),
   case htstream:decode(Pckt, Ht#stream.recv) of
      %% continue request streaming
      {[], Recv} ->
         {htstream:state(Recv), Ht#stream{recv=Recv}};

      %% GET Request
      {{'GET', Url, Head}, _Recv} ->
         <<"Upgrade">>   = pair:lookup('Connection', Head),
         <<"websocket">> = pair:lookup('Upgrade',    Head),
         Key  = pair:lookup(<<"Sec-Websocket-Key">>, Head),
         Hash = base64:encode(crypto:hash(sha, <<Key/binary, ?WS_GUID>>)),
         {Msg, _} = htstream:encode(
            {101, [{'Upgrade', <<"websocket">>}, {'Connection', <<"Upgrade">>}, {<<"Sec-WebSocket-Accept">>, Hash}], <<>>},
            htstream:new()
         ),
         pipe:a(Pipe, Msg),
         pipe:b(Pipe, {ws, self(), {'GET', Url, Head, []}}), %% @todo env
         {upgrade, ws_new(server, Url, [])};

      %% ANY Request
      {_, Recv} ->
         {eof, Ht#stream{recv=Recv}}       
   end.


