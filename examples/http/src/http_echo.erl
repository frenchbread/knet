-module(http_echo).

%%
%% konduit api
-export([init/1, free/2, ioctl/2, 'ECHO'/2]).

%%
%%
init(_) ->
   lager:info("echo ~p: server", [self()]),
   {ok, 'ECHO', undefined}.

%%
%%
free(_, _) ->
   ok.

%%
%%
ioctl(_, _) ->
   undefined.

%%
%%
'ECHO'({http, 'GET', Uri, _Heads}, S) -> 
   lager:info("echo ~p: GET ~p", [self(), Uri]),
   {reply,
      {200, Uri, [{'Content-Type', <<"text/plain">>}], message()},
      'ECHO',
      S
   };

'ECHO'({http, 'POST', Uri, Heads}, S) when is_list(Heads) ->
   lager:info("echo ~p: POST ~p", [self(), Uri]),
   Mime = proplists:get_value('Content-Type', Heads, <<"text/plain">>),
   {reply, 
      {200, Uri, [{'Content-Type', Mime}]},
      'ECHO',
      S
   };

'ECHO'({http, 'POST', Uri, Chunk}, S) when is_binary(Chunk) ->
   lager:info("echo ~p: chunk ~p", [self(), Chunk]),
   {reply,
      {send, Uri, <<"hhhh">>},   
      'ECHO',
      S
   };

'ECHO'({http, 'POST', Uri, eof}, S) ->
   lager:info("echo ~p: eof", [self()]),
   {reply,
      {eof, Uri},   
      'ECHO',
      S
   };

'ECHO'(_, S) ->
   {next_state, 'ECHO', S}.

message() ->
   Size = random:uniform(2048) + 1,
   << <<($A + random:uniform(26)):8>> || <<_:1>> <= <<0:Size>> >>.