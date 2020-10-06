-module(libp2p_stream_multistream).

-behavior(libp2p_stream).

-type prefix() :: binary().
-type path_handler() :: {Module :: atom(), Opts :: map()}.
-type handler() :: {prefix(), path_handler()}.
-type handlers() :: [handler()].

-export_type([handler/0, handlers/0]).

-type fsm_msg() ::
    {packet, Packet :: binary()} | {command, Cnd :: any()} | {error, Error :: term()}.

-type fsm_result() ::
    {keep_state, Data :: any()} |
    {keep_state, Data :: any(), libp2p_stream:actions()} |
    {next_state, State :: atom(), Data :: any()} |
    {next_state, State :: atom(), Data :: any(), libp2p_stream:actions()} |
    {stop, Reason :: term(), Data :: any()}.

-record(state, {
    handlers :: handlers(),
    fsm_state :: atom(),
    selected_handler = 1 :: pos_integer(),
    negotiation_timeout :: pos_integer()
}).

-define(PROTOCOL, "/multistream/1.0.0").
-define(MAX_LINE_LENGTH, 64 * 1024).
-define(DEFAULT_NEGOTIATION_TIME, 30000).

%% libp2p_stream
-export([init/2, handle_packet/4, handle_info/3]).
%% FSM states
-export([handshake/3, negotiate/3]).
%% Utility
-export([
    protocol_id/0,
    encode_line/1,
    encode_lines/1,
    decode_line/1,
    decode_lines/1
]).

init(Kind, Opts = #{handler_fn := HandlerFun}) ->
    init(Kind, maps:remove(handler_fn, Opts#{handlers => HandlerFun()}));
init(server, Opts = #{handlers := Handlers}) when is_list(Handlers), length(Handlers) > 0 ->
    lager:debug("init server multistream with handlers ~p", [Handlers]),
    NegotiationTime = maps:get(negotiation_timeout, Opts, ?DEFAULT_NEGOTIATION_TIME),
    {ok, #state{fsm_state = handshake, handlers = Handlers,
                negotiation_timeout = NegotiationTime},
        [
            {packet_spec, [varint]},
            {active, once},
            {send, encode_line(<<?PROTOCOL>>)},
            {timer, negotiate_timeout, NegotiationTime}
        ]};
init(client, Opts = #{handlers := Handlers}) when is_list(Handlers), length(Handlers) > 0 ->
    lager:debug("init client multistream with handlers ~p", [Handlers]),
    NegotiationTime = maps:get(negotiation_timeout, Opts, ?DEFAULT_NEGOTIATION_TIME),
    HandshakeTime = maps:get(handshake_timeout, Opts, rand:uniform(20000) + 15000),
    {ok, #state{fsm_state = handshake, handlers = Handlers,
                negotiation_timeout = NegotiationTime},
        [
            {packet_spec, [varint]},
            {active, once},
            %% have client/initiator kick things off by sending the initial multistream handshake
            {send, encode_line(<<?PROTOCOL>>)},
            {timer, handshake_timeout, HandshakeTime}
        ]};
init(_, _) ->
    {stop, missing_handlers}.

%%
%% FSM functions
%%

-spec handshake(libp2p_stream:kind(), fsm_msg(), #state{}) -> fsm_result().
handshake(client, {packet, Packet}, Data = #state{handlers = Handlers}) ->
    case binary_to_line(Packet) of
        <<?PROTOCOL>> ->
            %% Client got handshake from server.
            %% Request the first handler in handler list and move on to negotiation state.
            {Key, _} = select_handler(1, Data),
            lager:debug("Client negotiating handler using: ~p", [[K || {K, _} <- Handlers]]),
            {next_state, negotiate, Data#state{selected_handler = 1}, [
                {cancel_timer, handshake_timeout},
                {active, once},
                {send, encode_line(Key)}
            ]};
        Other ->
            handshake(client, {error, {handshake_mismatch, Other}}, Data)
    end;
handshake(client, {timeout, handshake_timeout}, Data = #state{}) ->
    %% The client failed to receive a handshake from the server after all retries
    handshake(client, {error, handshake_timeout}, Data);

handshake(server, {packet, Packet}, Data = #state{}) ->
    case binary_to_line(Packet) of
        <<?PROTOCOL>> ->
            {next_state, negotiate,
                Data, [{active, once}]};
        Other ->
            handshake(server, {error, {handshake_mismatch, Other}}, Data)
    end;
handshake(Kind, {error, Error}, Data = #state{}) ->
    lager:notice("~p handshake failed: ~p", [Kind, Error]),
    {stop, normal, Data};
handshake(Kind, Msg, State) ->
    handle_event(handshake, Kind, Msg, State).

-spec negotiate(libp2p_stream:kind(), fsm_msg(), #state{}) -> fsm_result().
negotiate(client, {packet, Packet}, Data = #state{}) ->
    %% Response from a request to the "selected" handler attempt.
    case binary_to_line(Packet) of
        <<"na">> ->
            %% select the next handler past selected, if there are any
            NextHandler = Data#state.selected_handler + 1,
            case select_handler(NextHandler, Data) of
                not_found ->
                    negotiate(client, {error, no_handlers}, Data);
                {Key, _} ->
                    lager:debug("Client negotiating next handler: ~p", [Key]),
                    {keep_state, Data#state{selected_handler = NextHandler}, [
                        {active, once},
                        {send, encode_line(Key)}
                    ]}
            end;
        Line ->
            %% Server agreed and switched to the handler.
            case select_handler(Data#state.selected_handler, Data) of
                {Key, {M, A}} when Key == Line ->
                    lager:debug("Client negotiated handler for: ~p, handler: ~p", [Line, M]),
                    {keep_state, Data, [{swap, M, A}]};
                _ ->
                    negotiate(client, {error, {unexpected_server_response, Line}}, Data)
            end
    end;
negotiate(server, {packet, Packet}, Data = #state{}) ->
    case binary_to_line(Packet) of
        <<"ls">> ->
            Keys = [Key || {Key, _} <- Data#state.handlers],
            {keep_state, Data, [
                {active, once},
                {send, encode_lines(Keys)}
            ]};
        Line ->
            case find_handler(Line, Data#state.handlers) of
                not_found ->
                    {keep_state, Data, [{send, encode_line(<<"na">>)}]};
                {_Prefix, {M, O}, LineRest} ->
                    lager:debug(
                        "Server negotiated handler for: ~p, handler: ~p, path: ~p",
                        [Line, M, LineRest]
                    ),
                    {keep_state, Data, [
                        {send, encode_line(Line)},
                        {cancel_timer, negotiate_timeout},
                        {swap, M, O#{path => LineRest}}
                    ]}
            end
    end;
negotiate(Kind, {error, Error}, Data = #state{}) ->
    lager:notice("~p negotiation failed: ~p", [Kind, Error]),
    %% Stop quietly after noticing the failure
    {stop, normal, Data};
negotiate(Kind, Msg, State) ->
    handle_event(negotiate, Kind, Msg, State).

%%
%% FSM implementation
%%

handle_message(Kind, Msg, Data0 = #state{fsm_state = State}) ->
    case erlang:apply(?MODULE, State, [Kind, Msg, Data0]) of
        {keep_state, Data} ->
            {noreply, Data};
        {keep_state, Data, Actions} ->
            {noreply, Data, Actions};
        {next_state, NextState, Data, Actions} ->
            {noreply, Data#state{fsm_state = NextState}, Actions};
        {stop, Reason, Data} ->
            {stop, Reason, Data};
        {stop, Reason, Data, Actions} ->
            {stop, Reason, Data, Actions}
    end.

handle_packet(Kind, _Header, Packet, Data = #state{}) ->
    handle_message(Kind, {packet, Packet}, Data).

handle_info(Kind, Msg, Data = #state{}) ->
    handle_message(Kind, Msg, Data).

%%
%% Utilities
%%

protocol_id() ->
    <<?PROTOCOL>>.

handle_event(State, server, {timeout, negotiate_timeout}, Data = #state{}) ->
    lager:notice("Server timeout negotiating with client (~p)", [State]),
    {stop, normal, Data};
handle_event(State, Kind, Msg, Data = #state{}) ->
    lager:warning("Unhandled ~p (~p) message: ~p", [Kind, State, Msg]),
    {keep_state, Data}.

select_handler(Index, #state{handlers = Handlers}) when Index =< length(Handlers) ->
    lists:nth(Index, Handlers);
select_handler(_Index, #state{}) ->
    not_found.

-spec encode_line(binary()) -> binary().
encode_line(Line) ->
    BinLine = line_to_binary(Line),
    libp2p_packet:encode_packet([varint], [byte_size(BinLine)], BinLine).

-spec line_to_binary(binary()) -> binary().
line_to_binary(Line) when byte_size(Line) > ?MAX_LINE_LENGTH ->
    erlang:error({max_line, byte_size(Line)});
line_to_binary(Line) ->
    <<Line/binary, $\n>>.

-spec decode_line(binary()) -> {Line :: binary(), Rest :: binary()}.
decode_line(Bin) ->
    case libp2p_packet:decode_varint(Bin) of
        {more, _} ->
            erlang:error(invalid_line);
        {Size, _} when Size > ?MAX_LINE_LENGTH ->
            erlang:error({max_line, Size});
        {Size, Data} ->
            case Data of
                <<BinLine:Size/binary, Rest/binary>> ->
                    {binary_to_line(BinLine), Rest};
                _ ->
                    erlang:error(invalid_line)
            end
    end.

-spec binary_to_line(binary()) -> binary().
binary_to_line(Bin) ->
    LineSize = byte_size(Bin) - 1,
    case Bin of
        <<Line:LineSize/binary, $\n>> ->
            Line;
        _ ->
            erlang:error(invalid_line)
    end.

-spec encode_lines([binary()]) -> binary().
encode_lines(Lines) when is_list(Lines) ->
    BinLines = lines_to_binary(Lines),
    libp2p_packet:encode_packet([varint], [byte_size(BinLines)], BinLines).

-spec lines_to_binary([binary()]) -> binary().
lines_to_binary(Lines) when is_list(Lines) ->
    EncodedLines = lists:foldr(
        fun(L, Acc) ->
            <<(encode_line(L))/binary, Acc/binary>>
        end,
        <<>>,
        Lines
    ),
    EncodedCount = libp2p_packet:encode_varint(length(Lines)),
    <<EncodedCount/binary, EncodedLines/binary>>.

-spec decode_lines(binary()) -> [binary()].
decode_lines(Bin) ->
    case libp2p_packet:decode_packet([varint], Bin) of
        {ok, _, BinLines, <<>>} ->
            binary_to_lines(BinLines);
        {ok, _, _, _} ->
            erlang:error(invalid_lines);
        {more, _} ->
            erlang:error(invalid_lines)
    end.

-spec binary_to_lines(binary()) -> [binary()].
binary_to_lines(Bin) ->
    case libp2p_packet:decode_varint(Bin) of
        {more, _} ->
            erlang:error(invalid_line_count);
        {Count, Data} ->
            binary_to_lines(Data, Count, [])
    end.

-spec binary_to_lines(binary(), non_neg_integer(), list()) -> [binary()].
binary_to_lines(_Bin, 0, Acc) ->
    lists:reverse(Acc);
binary_to_lines(Bin, Count, Acc) ->
    {Line, Rest} = decode_line(Bin),
    binary_to_lines(Rest, Count - 1, [Line | Acc]).

-spec find_handler(prefix(), handlers()) ->
    {Prefix :: prefix(), PathHandler :: path_handler(), Rest :: binary()} | not_found.
find_handler(_Line, []) ->
    not_found;
find_handler(Line, [{Prefix, Handler} | Handlers]) ->
    PrefixSize = byte_size(Prefix),
    case Line of
        <<Prefix:PrefixSize/binary, Rest/binary>> ->
            {Prefix, Handler, Rest};
        _ ->
            find_handler(Line, Handlers)
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

line_test() ->
    Line = <<"test-stream/1.0.0/path">>,
    Encoded = encode_line(Line),

    ?assertEqual({Line, <<>>}, decode_line(Encoded)),
    %% Strip end of binary to check invalid line response
    StrippedEnd = binary_part(Encoded, 0, byte_size(Encoded) - 1),
    ?assertError(invalid_line, decode_line(StrippedEnd)),
    %% Replace end of binary (newline) with another character to check
    %% error
    ?assertError(invalid_line, decode_line(<<StrippedEnd/binary, $\t>>)),

    MaxLineSize = ?MAX_LINE_LENGTH + 1,
    MaxLine = crypto:strong_rand_bytes(MaxLineSize),
    ?assertError({max_line, MaxLineSize}, encode_line(MaxLine)),

    MaxBin = <<(libp2p_packet:encode_varint(?MAX_LINE_LENGTH + 1))/binary>>,
    ?assertError({max_line, MaxLineSize}, decode_line(MaxBin)),

    %% Don't decode if you're expecting more. The stream should have
    %% been fed a complete packet
    ?assertError(invalid_line, decode_line(<<255>>)),

    ok.

lines_test() ->
    Lines = [
        <<"stream/1.0.0/path">>,
        <<"foo/1.0.0/path">>,
        <<"bar/1.0.0/path">>
    ],
    Encoded = encode_lines(Lines),

    ?assertEqual(Lines, decode_lines(Encoded)),
    ?assertError(
        invalid_lines,
        decode_lines(binary_part(Encoded, 1, byte_size(Encoded) - 1))
    ),

    %% Don't decode if you're expecting more. The stream should have
    %% been fed a complete packet
    ?assertError(invalid_lines, decode_lines(<<255>>)),
    ?assertError(invalid_line_count, decode_lines(<<1, 255>>)),

    ok.

-endif.
