-module(db_simple).
-compile({parse_transform, tq_db_transform}).

%% Test
-field({id,
		[
		 index,
		 {db_type, integer},
		 {type, integer}
		]}).
-field({name,
		[
		 required,
		 {db_alias, <<"db_name">>},
		 {db_type, string},
		 {type, binary},
		 db, record, init, get, set, 
		 {default, <<"Default name">>},
		 {mode, rw}
		]}).

-field({custom_in_record,
		[
		 {type, integer},
		 {db, false},
		 {record, true},
		 {get, custom},
		 {set, custom}
		]}).

-field({custom_not_in_record,
		[
		 {type, integer},
		 {db, false},
		 {record, false},
		 {get, custom},
		 {set, custom}
		]}).

-model([
		{table, <<"test">>}
	   ]).

set_custom_in_record(V, Model) ->
	Model2 = Model#?MODULE{custom_in_record = V},
	{ok, Model2}.

custom_in_record(Model) ->
	Model#?MODULE.custom_in_record.

set_custom_not_in_record(V, Model) ->
	put(test, V),
	{ok, Model}.

custom_not_in_record(_Model) ->
	get(test).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-define(join(A, B), list_to_atom(atom_to_list(A)++"_"++atom_to_list(B))).
-define(prefix_set(A), ?join(set, A)).

new_test() ->
	?assertEqual(#?MODULE{}, new()).

getter_setters_test_() ->
	Model = new(),
	Tests = [{id, 1},
			 {name, 2},
			 {custom_in_record, 3},
			 {custom_not_in_record, 4}],
	[{atom_to_list(F), fun() ->
							   SF = ?prefix_set(F),
							   {ok, Model2} = Model:SF(V),
							   V = Model2:F()
					   end} || {F, V} <- Tests].

proplist_test() ->
	Proplist = lists:keysort(1, [{id, 1},
								 {name, <<"test">>},
								 {custom_in_record, 10},
								 {custom_not_in_record, 20}]),
	
	{ok, Model} = from_proplist(Proplist),
	Proplist = lists:keysort(1, Model:to_proplist()).

bin_proplist_test() ->
	Proplist = lists:keysort(1, [{id, 1},
								 {name, <<"test">>},
								 {custom_in_record, 10},
								 {custom_not_in_record, 20}]),
	BinProplist = lists:keysort(1, [{<<"id">>, <<"1">>},
									{<<"name">>, <<"test">>},
									{<<"custom_in_record">>, <<"10">>},
									{<<"custom_not_in_record">>, <<"20">>}]),
	{ok, Model} = from_bin_proplist(BinProplist),
	Proplist = lists:keysort(1, Model:to_proplist()).	
	
-endif.

