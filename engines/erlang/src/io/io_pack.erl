%% pack.def as text (correlate.md, filter.md, fuse.md, quality.md "Pack"):
%% reading the file and splitting it into lines of tokens, in the three
%% line grammars the specs give. A load error is thrown as
%% {pack_error, Why} and caught by the function's parse/1.
-module(io_pack).
-export([read/2, fail/1, catching/1, words/1, words_strip_cr/1, strict_lines/1]).

%% {ok, Pack} from Parse(Text) of Dir/pack.def, or {error, Why}.
read(Dir, Parse) ->
    case file:read_file(filename:join(Dir, "pack.def")) of
        {ok, Text} -> Parse(Text);
        {error, R} -> {error, {read, R}}
    end.

fail(Why) -> throw({pack_error, Why}).

%% {ok, Fun()}, or {error, Why} for a load error thrown by fail/1.
catching(Fun) ->
    try {ok, Fun()}
    catch throw:{pack_error, Why} -> {error, Why}
    end.

%% correlate.md and filter.md: lines end at LF; "#" starts a comment; tokens
%% are separated by space, tab and CR; blank lines give no directive.
words(Text) ->
    [D || L <- binary:split(Text, <<"\n">>, [global]),
          D <- [tokens(L, [<<" ">>, <<"\t">>, <<"\r">>])], D =/= []].

%% fuse.md: one CR at the end of a line is removed, then the same with
%% space and tab only.
words_strip_cr(Text) ->
    [D || L0 <- binary:split(Text, <<"\n">>, [global]),
          D <- [tokens(strip_cr(L0), [<<" ">>, <<"\t">>])], D =/= []].

%% quality.md, steps 1 to 5: a final LF does not start another line; one CR
%% at the end of a line is removed; a control character other than tab
%% (U+0000 to U+001F or U+007F; a CR left inside the line is one) is a load
%% error; then tokens as fuse's.
strict_lines(Text) ->
    Parts = binary:split(Text, <<"\n">>, [global]),
    Lines = case lists:last(Parts) of
                <<>> -> lists:droplast(Parts);
                _ -> Parts
            end,
    [D || L0 <- Lines, L <- [strip_cr(L0)], ok <- [no_control(L)],
          D <- [tokens(L, [<<" ">>, <<"\t">>])], D =/= []].

no_control(Line) ->
    [fail({control_character, C}) || <<C>> <= Line, (C < 16#20 andalso C =/= $\t) orelse C =:= 16#7F],
    ok.

strip_cr(L) ->
    case byte_size(L) of
        0 -> L;
        N -> case binary:at(L, N - 1) of
                 $\r -> binary:part(L, 0, N - 1);
                 _ -> L
             end
    end.

tokens(Line, Seps) ->
    [Code | _] = binary:split(Line, <<"#">>),
    binary:split(Code, Seps, [global, trim_all]).
