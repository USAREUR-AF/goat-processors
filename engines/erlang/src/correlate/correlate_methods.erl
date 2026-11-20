%% Correlate methods: the registration point of a method, and the behaviour
%% a method module implements. The pack's `method` line names the method;
%% builtin/0 maps each name to its module. A pack loaded with
%% correlate:load_pack(Dir, #{methods => #{Name => Module}}) also knows the
%% extra methods. Adding a method is one entry here and one module.
-module(correlate_methods).
-export([builtin/0, table/1, default/0]).

%% Pack: {Required, Repeating, Once} directive names beyond the shared ones,
%% the method's defaults, one directive (or unknown), the range checks once
%% the whole file is read, and the last step of loading.
-callback directives() -> {[binary()], [binary()], [binary()]}.
-callback defaults() -> map().
-callback directive([binary()], map()) -> map() | unknown.
-callback check(map()) -> ok.
-callback finish_pack(map()) -> map().
%% Engine: the method's own state fields, the fields of a new entity, a
%% restarted entity, an accepted report, moving a prediction into a
%% source's frame for a test, the tick and the snapshot.
-callback new(map()) -> map().
-callback entity_fields() -> map().
-callback restarted(binary(), map()) -> map().
-callback reported(binary(), map()) -> map().
-callback move(map(), binary(), binary(), map()) -> map().
-callback tick(integer(), map()) -> {list(), list(), map()}.
-callback snapshot(map()) -> map().

builtin() -> #{<<"confirm">> => correlate_confirm, <<"assign">> => assign}.

table(Extra) -> maps:merge(builtin(), Extra).

%% Without a method line.
default() -> <<"confirm">>.
