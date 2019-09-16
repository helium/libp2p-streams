-module(stream_tcp_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    [
     init_stop_test,
     init_stop_action_test,
     init_ok_test,
     info_test,
     command_test,
     sock_close_test,
     active_test,
     swap_stop_test,
     swap_stop_action_test,
     swap_ok_test,
     connect_test
    ].



init_per_testcase(init_stop_action_test, Config) ->
    init_common(Config);
init_per_testcase(init_stop_test, Config) ->
    init_common(Config);
init_per_testcase(connect_test, Config) ->
    test_util:setup(),
    meck_stream(test_stream),
    Config;
init_per_testcase(_, Config) ->
    init_test_stream(init_common(Config)).

end_per_testcase(connect_test, _Config) ->
    ok;
end_per_testcase(_, Config) ->
    test_util:teardown_sock_pair(Config),
    meck_unload_stream(test_stream),
    ok.

init_common(Config) ->
    test_util:setup(),
    meck_stream(test_stream),
    test_util:setup_sock_pair(Config).

init_test_stream(Config) ->
    {_CSock, SSock} = ?config(client_server, Config),

    {ok, Pid} = libp2p_stream_tcp:start_link(server, #{socket => SSock,
                                                       mod => test_stream
                                                      }),
    gen_tcp:controlling_process(SSock, Pid),
    [{stream, Pid} | Config].


%%
%% Tests
%%

init_stop_action_test(Config) ->
    {CSock, SSock} = ?config(client_server, Config),

    libp2p_stream_tcp:start_link(server, #{socket => SSock,
                                           mod => test_stream,
                                           mod_opts => #{stop => {send, normal, <<"hello">>}}
                                          }),

    ?assertEqual(<<"hello">>, receive_packet(CSock)),
    ?assertEqual({error, closed}, gen_tcp:recv(CSock, 0, 10)),
    ok.

init_stop_test(Config) ->
    {CSock, SSock} = ?config(client_server, Config),

    libp2p_stream_tcp:start_link(server, #{socket => SSock,
                                           mod => test_stream,
                                           mod_opts => #{stop => normal} }),

    %% Since terminate doesn't get called on a close on startup, close
    %% the server socket here
    gen_tcp:close(SSock),

    %% ?assertEqual({error, normal}, StartResult),
    ?assertEqual({error, closed}, gen_tcp:recv(CSock, 0, 0)),

    ok.


init_ok_test(Config) ->
    {CSock, _SSock} = ?config(client_server, Config),
    Pid = ?config(stream, Config),

    send_packet(CSock, <<"hello">>),
    ?assertEqual(<<"hello">>, receive_packet(CSock)),

    ?assertEqual([{libp2p_stream_tcp, server}, {test_stream, server}], test_util:get_md(stack, Pid)),
    ?assertMatch({_, _}, test_util:get_md(addr_info, Pid)),

    ok.

sock_close_test(Config) ->
    {CSock, _SSock} = ?config(client_server, Config),
    Pid = ?config(stream, Config),

    gen_tcp:close(CSock),

    ?assert(test_util:pid_should_die(Pid)),
    ok.

active_test(Config) ->
    {CSock, SSock} = ?config(client_server, Config),
    Pid = ?config(stream, Config),

    meck:expect(test_stream, handle_info,
               fun(server, {active, Active}, State) ->
                       {noreply, State, [{active, Active}]}
               end),

    %% Changing active on a socket can take a few cycles. Checking for
    %% an active state by waiting for the expected value.
    ActiveShouldBe =
        fun(Val) ->
                ok == test_util:wait_until(fun() ->
                                                   {ok, [{active, Val}]} == inet:getopts(SSock, [active])
                                           end)
        end,

    %% Set active to true, ensure active stays true even when an
    %% application level packet is exchanged
    Pid ! {active, true},
    send_packet(CSock, <<"hello">>),
    ?assert(ActiveShouldBe(true)),
    %% Set active to false means socket active goes to false to
    Pid ! {active, false},
    ?assert(ActiveShouldBe(false)),
    %% Set active to once and ensure that the socket active is true.
    Pid ! {active, once},
    ?assert(ActiveShouldBe(true)),
    %% Once an application level packet is sent the socket active
    %% should be set to false since we don't want any more data
    send_packet(CSock, <<"hello">>),
    ?assert(ActiveShouldBe(false)),

    ok.


info_test(Config) ->
    {CSock, _SSock} = ?config(client_server, Config),
    Pid = ?config(stream, Config),

    Pid ! no_handler,

    meck:expect(test_stream, handle_info,
               fun(server, {send, Data}, State) ->
                       Packet = encode_packet(Data),
                       {noreply, State, [{send, Packet}]};
                  (server, no_actions, State) ->
                       {noreply, State};
                  (server, multi_active, State) ->
                       %% Excercise same action having no effect
                       {noreply, State, [{active, once}, {active, once}]};
                  (server, {stop, Reason}, State) ->
                       {stop, Reason, State}
               end),

    Pid ! {send, <<"hello">>},
    ?assertEqual(<<"hello">>, receive_packet(CSock)),

    Pid ! no_actions,
    Pid ! multi_active,
    Pid ! {stop, normal},

    ?assert(test_util:pid_should_die(Pid)),

    ok.

command_test(Config) ->
    {CSock, _SSock} = ?config(client_server, Config),
    Pid = ?config(stream, Config),

    ?assertEqual(ok, libp2p_stream_transport:command(Pid, no_implementation)),

    meck:expect(test_stream, handle_command,
               fun(server, {send, Data}, _From, State) ->
                       Packet = encode_packet(Data),
                       {reply, send, State, [{send, Packet}]};
                  (server, no_action, _From, State) ->
                       {reply, no_action, State};
                  (server, noreply_no_action, From, State) ->
                       {noreply, State#{noreply_from => From}};
                  (server, reply_noreply, _From, State=#{noreply_from := NoReplyFrom}) ->
                       {reply, ok, State, [{reply, NoReplyFrom, reply_noreply}]};
                  (_, swap_kind, _From, State) ->
                       {reply, ok, State, [swap_kind]};
                  (Kind, kind, _From, State) ->
                       {reply, Kind, State}
               end),

    ?assertEqual(no_action, libp2p_stream_tcp:command(Pid, no_action)),

    %% Call a command with noreply in a new pid
    Parent = self(),
    spawn(fun() ->
                  Reply = libp2p_stream_tcp:command(Pid, noreply_no_action),
                  Parent ! {noreply_reply, Reply}
          end),
    %% Let the spawned function run
    timer:sleep(100),
    %% Now get it to reply with a reply action
    ?assertEqual(ok, libp2p_stream_tcp:command(Pid, reply_noreply)),

    receive
        {noreply_reply, reply_noreply} -> ok
    after 500 ->
            ct:fail(timeout_noreply_reply)
    end,

    ?assertEqual(send, libp2p_stream_tcp:command(Pid, {send, <<"hello">>})),
    ?assertEqual(<<"hello">>, receive_packet(CSock)),

    %% Swap kind to client and back
    ?assertEqual(ok, libp2p_stream_tcp:command(Pid, swap_kind)),
    ?assertEqual(client, libp2p_stream_tcp:command(Pid, kind)),
    ?assertEqual([{libp2p_stream_tcp, server}, {test_stream, client}], test_util:get_md(stack, Pid)),
    ?assertEqual(ok, libp2p_stream_tcp:command(Pid, swap_kind)),
    ?assertEqual(server, libp2p_stream_tcp:command(Pid, kind)),
    ?assertEqual([{libp2p_stream_tcp, server}, {test_stream, server}], test_util:get_md(stack, Pid)),

    ok.

swap_stop_test(Config) ->
    {CSock, _SSock} = ?config(client_server, Config),
    Pid = ?config(stream, Config),

    meck:expect(test_stream, handle_command,
               fun(server, {swap, Mod, ModOpts}, _From, State) ->
                       {reply, ok, State, [{swap, Mod, ModOpts}]}
               end),

    libp2p_stream_tcp:command(Pid, {swap, test_stream, #{stop => normal}}),

    ?assert(test_util:pid_should_die(Pid)),
    ?assertEqual({error, closed}, gen_tcp:recv(CSock, 0, 0)),

    ok.


swap_stop_action_test(Config) ->
    {CSock, _SSock} = ?config(client_server, Config),
    Pid = ?config(stream, Config),

    meck:expect(test_stream, handle_command,
               fun(server, {swap, Mod, ModOpts}, _From, State) ->
                       {reply, ok, State, [{swap, Mod, ModOpts}]}
               end),

    libp2p_stream_tcp:command(Pid, {swap, test_stream, #{stop => {send, normal, <<"hello">>}}}),

    ?assert(test_util:pid_should_die(Pid)),

    ?assertEqual(<<"hello">>, receive_packet(CSock)),
    ?assertEqual({error, closed}, gen_tcp:recv(CSock, 0, 0)),

    ok.

swap_ok_test(Config) ->
    {CSock, _SSock} = ?config(client_server, Config),
    Pid = ?config(stream, Config),

    meck:expect(test_stream, handle_command,
               fun(server, {swap, Mod, ModOpts}, _From, State) ->
                       {reply, ok, State, [{swap, Mod, ModOpts}]}
               end),

    libp2p_stream_tcp:command(Pid, {swap, test_stream, #{}}),

    send_packet(CSock, <<"hello">>),
    ?assertEqual(<<"hello">>, receive_packet(CSock)),

    ok.

connect_test(_Config) ->
    {ok, LSock} = gen_tcp:listen(0, [binary, {active, false}]),
    {ok, LPort} = inet:port(LSock),

    Parent = self(),
    spawn(fun() ->
                  {ok, ServerSock} = gen_tcp:accept(LSock),
                  gen_tcp:controlling_process(ServerSock, Parent),
                  Parent ! {accepted, ServerSock}
          end),

    {ok, Pid} = libp2p_stream_tcp:start_link(client,
                                             #{addr => "/ip4/127.0.0.1/tcp/" ++ integer_to_list(LPort),
                                               mod => test_stream
                                              }),

    SSock = receive
                {accepted, S} -> S
            after 5000 ->
                    ct:fail(timout_no_connect)
            end,

    ?assertEqual(libp2p_stream_tcp:addr_info(Pid), {ok, test_util:get_md(addr_info, Pid)}),
    gen_tcp:close(SSock),
    ?assert(test_util:pid_should_die(Pid)),
    ?assertEqual({error, einval}, libp2p_stream_tcp:addr_info(SSock)),
    ?assertEqual({error, closed}, libp2p_stream_tcp:addr_info(Pid)),

    {ok, C1Pid} = libp2p_stream_tcp:start_link(client, #{addr => "invalid/addr",
                                                         mod => test_stream,
                                                         stream_handler => {self(), connect_test}
                                                        }),
    unlink(C1Pid),

    receive
        {stream_error, connect_test, {error, {invalid_address, _}}} -> ok
    after 5000 -> ct:fail(timeout_connect_invalid_addr)
    end,

    gen_tcp:close(LSock),
    {ok, C2Pid} = libp2p_stream_tcp:start_link(client,
                                               #{addr => "/ip4/127.0.0.1/tcp/" ++ integer_to_list(LPort),
                                                 mod => test_stream,
                                                 stream_handler => {self(), connect_test}
                                                }),
    unlink(C2Pid),

    receive
        {stream_error, connect_test, {error, econnrefused}} -> ok
    after 5000 ->
            %% failed to connect to closed socket didn't get here
            ct:fail(timeout_connect_refused)
    end,

    ok.


%%
%% Utilities
%%

encode_packet(Data) ->
    DataSize = byte_size(Data),
    libp2p_packet:encode_packet([u8], [DataSize], Data).

send_packet(Sock, Data) ->
    Packet = encode_packet(Data),
    ok = gen_tcp:send(Sock, Packet).

receive_packet(Sock) ->
    {ok, Bin} = gen_tcp:recv(Sock, 0, 500),
    {ok, [DataSize], Data, <<>>} = libp2p_packet:decode_packet([u8], Bin),
    ?assertEqual(DataSize, byte_size(Data)),
    Data.


meck_stream(Name) ->
    meck:new(Name, [non_strict]),
    meck:expect(Name, init,
                fun(_, Opts=#{stop := {send, Reason, Data}}) ->
                        Packet = encode_packet(Data),
                        {stop, Reason, Opts, [{send, Packet}]};
                   (_, #{stop := Reason}) ->
                        {stop, Reason};
                   (_, Opts) ->
                        {ok, Opts, [{packet_spec, [u8]},
                                    {active, once}
                                   ]}
                end),
    meck:expect(Name, handle_packet,
               fun(_, _, Data, State) ->
                       Packet = encode_packet(Data),
                       {noreply, State, [{send, Packet}]}
               end),
    ok.


meck_unload_stream(Name) ->
    meck:unload(Name).
