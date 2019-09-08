-module(libp2p_stream).


-type kind() :: client | server.

-type active() :: once | true | false.

-type action() ::
        {send, Data::binary()} |
        {swap, Module::atom(), ModState::any()} |
        {packet_spec, libp2p_packet:spec()} |
        {active, active()} |
        {reply, To::term(), Reply::term()} |
        {timer, Key::term(), Timeout::non_neg_integer()} |
        {cancel_timer, Key::term()} |
        swap_kind.

-type actions() :: [action()].
-export_type([kind/0, active/0, action/0, actions/0]).

-type init_result() ::
        {ok, ModState::any(), actions()} |
        {stop, Reason::term()} |
        {stop, Reason::term(), ModState::any(), actions()}.

-type handle_info_result() ::
        {noreply, ModState::any()} |
        {noreply, ModState::any(), actions()} |
        {stop, Reason::term(), ModState::any()} |
        {stop, Reason::term(), ModState::any(), actions()}.

-type handle_packet_result() :: handle_info_result().
-type handle_command_result() ::
        {reply, Reply::term(), ModState::any()} |
        {reply, Reply::term(), ModState::any(), actions()} |
        {noreply, ModState::any()} |
        {noreply, ModState::any(), actions()}.

-export_type([init_result/0,
              handle_packet_result/0,
              handle_info_result/0,
              handle_command_result/0]).

-callback init(kind(), Args::map()) -> init_result().
-callback command(ModState::any(), Command::any()) -> term().

-callback handle_packet(Kind::kind(),
                        Header::libp2p_packet:header(),
                        Packet::binary(),
                        ModState::any()) -> handle_packet_result().
-callback handle_info(Kind::kind(),
                      Msg::term(),
                      ModState::any()) -> handle_info_result().
-callback handle_command(Kind::kind(),
                         Command::any(),
                         From::term(),
                         ModState::any()) -> handle_command_result().

-optional_callbacks([handle_command/4, command/2, handle_info/3]).
