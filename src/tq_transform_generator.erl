%% Copyright (c) 2011-2013, Jakov Kozlov <xazar.studio@gmail.com>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(tq_transform_generator).

-include("include/records.hrl").
-include("include/ast_helpers.hrl").

-export([build_model/1]).

-define(atom_join(A, B), list_to_atom(atom_to_list(A) ++ "_" ++ atom_to_list(B))).
-define(prefix_set(A), ?atom_join(set, A)).
-define(changed_suffix(A), ?atom_join(A, '$changed')).

%% Build result ast.

-spec build_model(Model) -> {InfoAst, FunctionsAst} when
	  Model :: #model{},
	  InfoAst :: erl_syntax:syntaxTree(),
	  FunctionsAst :: erl_syntax:syntaxTree().
build_model(Model) ->
	Builders = [
				fun build_main_record/1,
				fun build_getter_and_setters/1,
				fun build_proplists/1,
				fun build_internal_functions/1,
				fun build_validators/1
			   ],
	lists:foldl(fun(F, {IBlock, FBlock}) ->
						{IB, FB} = F(Model),
						{[IB|IBlock], [FB|FBlock]}
				end, {[], []}, Builders).

build_main_record(#model{module=Module, fields=Fields}) ->
	FieldsInRecord = [F || F <- Fields, F#field.stores_in_record],
	RecordFieldNames = [case F#field.record_options#record_options.default_value of
							undefined ->
								case is_write_only(F) of
									true -> {F#field.name, '$write_only_stumb$'};
									false -> F#field.name
								end;
							Val -> {F#field.name, Val}
						end || F <- Fields, F#field.stores_in_record],
	DbFieldNames =  [{?changed_suffix(F#field.name),
					  F#field.record_options#record_options.default_value =/= undefined}
					 || F <- FieldsInRecord],
	RecordFields = lists:flatten([{'$is_new$', true},
								  RecordFieldNames,
								  DbFieldNames]),
	Attribute = def_record(Module, RecordFields),
	{[Attribute], []}.

build_getter_and_setters(#model{module=Module, fields=Fields}) ->
	NewFun = ?function(new, [?clause([], none, [?record(Module,[])])]),
	NewExport = ?export(new, 0),
	GetterFields = [F || F <- Fields, F#field.getter],
	GetterFuns = [getter(Module, F) || F <- GetterFields],
	GetterExports = export_funs(GetterFuns),
	CustomGettersExports = ?export_all([{F#field.name, 1} || F <- Fields, F#field.getter =:= custom]),

	SetterFields = [F || F <- Fields, F#field.setter],
	SetterFuns = [setter(Module, F) || F <- SetterFields],
	SetterExports = export_funs(SetterFuns),
	CustomSettersExports = ?export_all([{?prefix_set(F#field.name), 2} || F <- Fields, F#field.setter =:= custom]),

	IsNewFun = ?function(is_new, [?clause([?var('Model')], none, [?access(?var('Model'), Module, '$is_new$')])]),
	IsNewExport = ?export(is_new, 1),
	Funs = [NewFun, GetterFuns, SetterFuns, IsNewFun],
	Exports = [NewExport, GetterExports, CustomGettersExports, SetterExports, CustomSettersExports, IsNewExport],
	{Exports, Funs}.

getter(Module, #field{name=Name}) ->
	?function(Name, [?clause([?var('Model')], none, [?access(?var('Model'), Module, Name)])]).
setter(Module, #field{name=Name}) ->
	?function(?prefix_set(Name),
			  [?clause([?var('Val'),?var('Model')], none,
					   [?cases(?eeq(?var('Val'),?access(?var('Model'), Module, Name)),
							   [?clause([?atom(true)], none,
										[?var('Model')]),
								?clause([?atom(false)], none,
										[?record(?var('Model'),Module,
												 [?field(Name,?var('Val')),
												  ?field(?changed_suffix(Name),?atom(true))])])])])]).

build_proplists(Model) ->
	Funs = [to_proplist_function(Model),
			from_proplist_functions(Model),
			from_bin_proplist_function(Model)
		   ],
	{Public0, Private0} = lists:foldl(fun({P, Pr}, {Pub, Priv}) ->
											{[P|Pub], [Pr|Priv]};
									   (P, {Pub, Priv}) ->
											{[P|Pub], Priv}
									end, {[], []}, Funs),
	{Public, Private} = {lists:flatten(Public0), lists:flatten(Private0)},
	Exports = export_funs(Public),
	{Exports, Public ++ Private}.

to_proplist_function(#model{fields=Fields}) ->
	DefaultOpts = ?abstract([safe]),
	Fun_ = fun(AccessModeOpt) ->
				   ?list([?tuple([?atom(F#field.name), ?apply(F#field.name, [?var('Model')])]) ||
							 F <- Fields,
							 element(AccessModeOpt, F#field.mode),
							 F#field.getter =/= false
						 ])
		   end,
	Fun1 = ?function(to_proplist,
					 [?clause([?var('Model')], none,
							  [?apply(to_proplist, [DefaultOpts, ?var('Model')])])]),
	Fun2 = ?function(to_proplist,
					 [?clause([?var('Opts'), ?var('Model')], none,
							  [?cases(?apply(lists, member, [?atom(safe), ?var('Opts')]),
									  [?clause([?atom(true)], none,
											   [Fun_(#access_mode.sr)]),
									   ?clause([?atom(false)], none,
											   [Fun_(#access_mode.r)])])])]),
	[Fun1, Fun2].

from_proplist_functions(#model{fields=Fields}) ->
	DefaultOpts = ?abstract([safe]),
	Fun1 = ?function(from_proplist,
					 [?clause([?var('Proplist')], none,
							  [?apply(from_proplist, [?var('Proplist'), DefaultOpts, ?apply(new, [])])])]),
	Fun2 = ?function(from_proplist,
					 [?clause([?var('Proplist'),?var('Model')], none,
							  [?apply(from_proplist,[?var('Proplist'), DefaultOpts, ?var('Model')])])]),
	Fun3 = ?function(from_proplist,
					 [?clause([?var('Proplist'), ?var('Opts'), ?var('Model')], none,
							  [?match(?var('Fun'), ?cases(?apply(lists, member, [?atom(safe), ?var('Opts')]),
														  [?clause([?atom(true)], none,
																   [?func(from_proplist_safe_, 2)]),
														   ?clause([?atom(false)], none,
																   [?func(from_proplist_unsafe_, 2)])])),
							   ?apply(tq_transform_utils,error_writer_foldl, [?var('Fun'), ?var('Model'), ?var('Proplist')])])]),
					 DefaultClasuse = [?clause([?tuple([?var('Field'),?underscore]), ?underscore], none,
											   [?error(?atom(unknown), ?var('Field'))])],
	Fun_ = fun(Suffix, AccessModeOpt) ->
				   ?function(?atom_join(from_proplist, Suffix),
							 [?clause(
								 [?tuple([?atom(F#field.name),?var('Val')]), ?var('Model')], none,
								 [?ok(?apply(?prefix_set(F#field.name), [?var('Val'), ?var('Model')]))])
							  || F <- Fields,
								 F#field.setter =/= undefined,
								 element(AccessModeOpt, F#field.mode)] ++ DefaultClasuse)
		   end,
	FunSafe_ = Fun_(safe_, #access_mode.sw),
	FunUnsafe_ = Fun_(unsafe_, #access_mode.w),
	{[Fun1, Fun2, Fun3], [FunSafe_, FunUnsafe_]}.

from_bin_proplist_function(#model{fields=Fields}) ->
	DefaultOpts = ?abstract([]),
	Fun1 = ?function(from_bin_proplist,
					 [?clause([?var('BinProplist')], none,
							  [?apply(from_bin_proplist, [?var('BinProplist'), DefaultOpts, ?apply(new, [])])])]),
	Fun2 = ?function(from_bin_proplist,
					 [?clause([?var('BinProplist'), ?var('Model')], none,
							  [?apply(from_bin_proplist, [?var('BinProplist'), DefaultOpts, ?var('Model')])])]),
	Fun3 = ?function(from_bin_proplist,
					 [?clause([?var('BinProplist'), ?var('Opts'), ?var('Model')], none,
							  [?match(?var('Fun'), ?cases(?apply(lists, member, [?atom(safe), ?var('Opts')]),
														  [?clause([?atom(true)], none,
																   [?func(from_bin_proplist_safe_, 2)]),
														   ?clause([?atom(false)], none,
																   [?func(from_bin_proplist_unsafe_, 2)])])),
							   ?apply(tq_transform_utils,error_writer_foldl, [?var('Fun'), ?var('Model'), ?var('BinProplist')])])]),
	DefaultClasuse = [?clause([?tuple([?var('Field'),?underscore]), ?underscore], none,
							  [?error(?atom(unknown), ?var('Field'))])],
	SetterClause = fun(F, Var) -> ?ok(?apply(?prefix_set(F#field.name), [?var(Var), ?var('Model')])) end,
	Cases = fun(F, A) -> ?cases(A,
							   [?clause([?ok(?var('Val'))], none,
										[SetterClause(F, 'Val')]),
								?clause([?error(?var('Reason'))], none,
										[?error(?tuple([?var('Reason'), ?atom(F#field.name)]))])])
		   end,
	Fun_ = fun(Suffix, AccessModeOpt) ->
				   ?function(?atom_join(from_bin_proplist, Suffix),
							 [?clause(
								 [?tuple([?abstract(atom_to_binary(F#field.name)),?var('Bin')]), ?var('Model')], none,
								 [case F#field.record_options#record_options.type_constructor of
									  none ->
										  SetterClause(F, 'Bin');
									  {Mod, Fun} ->
										  Cases(F, ?apply(Mod, Fun, [?var('Bin')]));
									  Fun ->
										  Cases(F, ?apply(Fun, [?var('Bin')]))
								  end])
							  || F <- Fields,
								 F#field.setter =/= undefined,
								 element(AccessModeOpt, F#field.mode)] ++ DefaultClasuse)
		   end,
	FunSafe_ = Fun_(safe_, #access_mode.sw),
	FunUnsafe_ = Fun_(unsafe_, #access_mode.w),
	{[Fun1, Fun2, Fun3], [FunSafe_, FunUnsafe_]}.

build_internal_functions(Model) ->
	Funs = [changed_fields_function(Model),
			field_constructor_function(Model),
			constructor1_function(Model)
		   ],
	Exports = export_funs(Funs),
	{Exports, Funs}.

changed_fields_function(#model{module=Module, fields=Fields}) ->
	AllowedFields = [F#field.name || F <- Fields,
									 F#field.stores_in_record,
									 F#field.setter,
									 F#field.mode#access_mode.sw],
	ListAst = ?list([?tuple([?atom(F),
							 ?access(?var('Model'), Module, F),
							 ?access(?var('Model'), Module, ?changed_suffix(F))
							])
					 || F <- AllowedFields]),
	?function(get_changed_fields,
			  [?clause([?var('Model')], none,
					   [?list_comp(?tuple([?var('Name'), ?var('Val')]),
								   [?generator(?tuple([?var('Name'), ?var('Val'), ?var('Changed')]),
											   ListAst),
									?var('Changed')]
								  )])]).

constructor1_function(#model{init_fun=InitFun, module=Module}) ->
	SetIsNotNew = ?record(?var('Model'), Module, [?field('$is_new$', ?atom(false))]),
	FinalForm = case InitFun of
					undefined -> SetIsNotNew;
					{Mod, Fun} -> ?apply(Mod, Fun, [SetIsNotNew]);
					Fun -> ?apply(Fun, [SetIsNotNew])
				end,
	?function(constructor,
			  [?clause([?var('Fields')], none,
					   [?match(?var('Constructors'),
							   ?list_comp(?apply(field_constructor,[?var('F')]),
										  [?generator(?var('F'), ?var('Fields'))])),
						?func([?clause([?var('List')], none,
									   [?match(?var('Model'),
											   ?apply(lists, foldl,
													  [?func([?clause([?tuple([?var('F'), ?var('A')]), ?var('M')], none,
																	  [?apply_(?var('F'), [?var('A'), ?var('M')])])]),
												  ?apply(new, []),
												  ?apply(lists,zip,[?var('Constructors'),?var('List')])])),
										FinalForm
								  ]
									  )])])]).

field_constructor_function(#model{fields=Fields}) ->
	DefaultClasuse = ?clause([?var('Fun')], [?nif_is_function(?var('Fun'))], [?var('Fun')]),
	?function(field_constructor,
			  [?clause([?atom(F#field.name)], none,
					   [?func([?clause([?var('Val'), ?var('Model')], none,
									   [?apply(?prefix_set(F#field.name), [?var('Val'), ?var('Model')])])])]) ||
				  F <- Fields,
				  F#field.setter
			  ] ++ [DefaultClasuse]).


build_validators(#model{module=Module, fields=Fields}) ->
	ValidatorFun = ?function(validator,
							 [?clause([?atom(F#field.name)], none,
									  [validator([],
												 F#field.is_required,
												 is_write_only(F))]) || F <- Fields]),
	ValidFun = ?function(valid,
						 [?clause([?var('Model')], none,
								  [?match(?var('Data'),
										  ?list([?tuple(
													[?atom(F#field.name),
													 ?apply(validator, [?atom(F#field.name)]),
													 ?access(?var('Model'), Module, F#field.name)])
												 || F <- Fields,
													F#field.stores_in_record])),
								   ?apply(tq_transform_utils, valid, [?var('Data')])
								  ])]),
	Funs = [ValidatorFun, ValidFun],
	Exports = export_funs(Funs),
	{Exports, Funs}.

validator(_Validators, IsRequired, IsWriteOnly) ->
	WO_clause = ?clause([?atom('$write_only_stumb$')], none, [?atom(ok)]),
	Req_clause = ?clause([?atom(undefined)], none, [?error(?atom(required))]),
	Main_clause = ?clause([?underscore], none, [?atom(ok)]),
	Clauses = acc_if(IsWriteOnly, WO_clause,
					 acc_if(IsRequired, Req_clause,
							[Main_clause])),
	?func(Clauses).

%% Internal helpers.

is_write_only(Field) ->
	AccessMode = Field#field.mode,
	not AccessMode#access_mode.sr.

def_record(Name, Fields) ->
	?def_record(Name, [case F of
						   Atom when is_atom(F) -> ?field(Atom);
						   {Atom, Value} when is_atom(Atom) -> ?field(Atom, ?abstract(Value))
					   end || F <- Fields]).

export_funs(Funs) ->
	?export_all([{erl_syntax:atom_value(erl_syntax:function_name(F)),
				  erl_syntax:function_arity(F)} || F <- Funs]).

acc_if(true, Val, Acc) -> [Val|Acc];
acc_if(false, _, Acc) -> Acc.

atom_to_binary(Atom) ->
	list_to_binary(atom_to_list(Atom)).