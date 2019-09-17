-module(libp2p_stream_muxer).

-type opts() :: #{ handlers => libp2p_stream_multistream:handlers()}.
-export_type([opts/0]).

-export([dial/1,
         dial/2,
         identify/2,
         streams/2
        ]).

-spec dial(pid()) -> {ok, pid()} | {error, term()}.
dial(MuxerPid) ->
    dial(MuxerPid, #{}).

-spec dial(pid(), opts()) -> {ok, pid()} | {error, term()}.
dial(MuxerPid, Opts) ->
    libp2p_stream_transport:command(MuxerPid, {stream_dial, Opts}).


identify(MuxerPid, Opts=#{ identify_keys := _Keys, identify_handler := {_ResultPid, _ResultData}}) ->
    MuxerPid ! {stream_identify, Opts}.

-spec streams(pid(), libp2p_stream:kind()) -> {ok, [pid()]} | {error, term()}.
streams(MuxerPid, Kind) ->
    libp2p_stream_transport:command(MuxerPid, {stream_streams, Kind}).
