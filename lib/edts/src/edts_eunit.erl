%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Provides support for running eunit tests from EDTS
%%% @end
%%% @author Håkan Nilsson <haakan@gmail.com>
%%% @copyright
%%% Copyright 2012 Håkan Nilsson <haakan@gmail.com>
%%%           2013 Thomas Järvstrand <tjarvstrand@gmail.com>
%%%
%%% This file is part of EDTS.
%%%
%%% EDTS is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU Lesser General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% EDTS is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU Lesser General Public License for more details.
%%%
%%% You should have received a copy of the GNU Lesser General Public License
%%% along with EDTS. If not, see <http://www.gnu.org/licenses/>.
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration =======================================================
-module(edts_eunit).

%%%_* Includes =================================================================
-include_lib("eunit/include/eunit.hrl").

%%%_* Exports ==================================================================

%% API
-export([ run_tests/1
        ]).

%%%_* Defines ==================================================================
%-define(DEBUG, true).

%%%_* Types ====================================================================
-type info()    :: orddict:orddict().
-type result()  :: ok() | error().
-type ok()      :: {ok, {summary(), [test()]}}.
-type error()   :: {error, term()}.
-type summary() :: orddict:orddict().
-type test()    :: {mfa(), [info()]}.
-type reason()  :: atom().

-export_type([info/0,
              result/0,
              ok/0,
              error/0,
              summary/0,
              test/0,
              reason/0
             ]).

%%%_* API ======================================================================

%%------------------------------------------------------------------------------
%% @doc Run eunit tests on Module and return result as "issues".
-spec run_tests(module()) -> {ok, [edts_code:issue()]}
                           | {error, term()}.
%%------------------------------------------------------------------------------
run_tests(Module) ->
  case do_run_tests(Module) of
    {ok, {Summary, Results}} ->
      debug("run tests returned ok: ~p", [Summary]),
      {ok, Source} = edts_code:get_module_source(Module),
      {ok, format_results(Source, Results)};
    {error, Reason} = Error ->
      debug("Error in eunit test result in ~p: ~p", [Module, Reason]),
      Error
  end.

%%%_* Internal functions =======================================================

-spec do_run_tests(module()) -> result().
do_run_tests(Module) ->
  debug("running eunit tests in: ~p", [Module]),
  Listener = edts_eunit_listener:start([{parent, self()}]),
  case eunit_server:start_test(eunit_server, Listener, Module, []) of
    {ok, Ref}    -> do_run_tests(Ref, Listener, 20000);
    {error, Err} -> {error, Err}
  end.

-spec do_run_tests(reference(), pid(), non_neg_integer()) -> result().
do_run_tests(Ref, Listener, Timeout) ->
  debug("waiting for start..."),
  receive
    {start, Ref} ->
      Listener ! {start, Ref}
  end,
  debug("waiting for result..."),
  receive
    {result, Ref, Result} -> {ok, Result};
    {error, Err}          -> {error, Err}
  after
    Timeout -> {error, timeout}
  end.

format_results(Source, Results) ->
  lists:map(fun(Result) -> format_successful(Source, Result) end,
            orddict:fetch(successful, Results)) ++
    lists:map(fun(Result) -> format_failed(Source, Result) end,
              orddict:fetch(failed, Results)) ++
    lists:map(fun(Result) -> format_cancelled(Source, Result) end,
              orddict:fetch(cancelled, Results)).


format_successful(Source, Result) ->
  Line = proplists:get_value(line, Result),
  {'passed-test', Source, Line, "no asserts failed"}.

format_failed(Source, Result) ->
  Line = proplists:get_value(line, Result),
  {error, Err} = proplists:get_value(status, Result),
  {'failed-test', Source, Line, format_error(Err)}.

format_cancelled(Source, Result) ->
  Line = proplists:get_value(line, Result),
  {'cancelled-test', Source, Line, to_str(proplists:get_value(reason, Result))}.

format_error({error, {Reason, Info}, _Stack}) ->
  {ExpectProp, ValueProp} = reason_to_props(Reason),
  Expected = proplists:get_value(ExpectProp, Info),
  Value = proplists:get_value(ValueProp, Info),
  io_lib:format("~p\n"
                "expected: ~s\n"
                "value:    ~s",
         [Reason, to_str(Expected), to_str(Value)]).

reason_to_props(Reason) ->
  Mapping =
    [{assertException_failed, {pattern, unexpected_success}},
     {assertNotException_failed, {pattern, unexpected_exception}},
     {assertCmdOutput_failed, {expected_output, output}},
     {assertCmd_failed, {expected_status, status}},
     {assertEqual_failed, {expected, value}},
     {assertMatch_failed, {pattern, value}},
     {assertNotEqual_failed, {expected, expected}},
     {assertNotMatch_failed, {pattern, value}},
     {assertion_failed, {expected, value}},
     {command_failed, {expected_status, status}}],
  case lists:keyfind(Reason, 1, Mapping) of
    {Reason, Props} -> Props;
    false           -> {undefined, undefined}
  end.


-spec to_str(term()) -> string().
to_str(Term) ->
  %% Remave line breaks
  [C || C <- lists:flatten(io_lib:format("~p", [Term])), C =/= $\n].

debug(Str) -> debug(Str, []).

-ifdef(DEBUG).
debug(FmtStr, Args) -> error_logger:info_msg(FmtStr, Args).
-else.
debug(_FmtStr, _Args) -> ok.
-endif.

%%%_* Unit tests ===============================================================

do_run_tests_ok_test() ->
  {Ref, Pid} = run_tests_common(),
  Pid ! {result, Ref, foo},
  assert_receive({ok, foo}).

do_run_tests_error_test() ->
  {_Ref, Pid} = run_tests_common(),
  Pid ! {error, foobar},
  assert_receive({error, foobar}).

do_run_tests_timeout_test() ->
  Ref = make_ref(),
  self() ! {start, Ref},
  ?assertEqual({error, timeout}, do_run_tests(Ref, self(), 0)).

format_results_test_() ->
  ErrorInfo = [{expected, foo},
               {value, bar}],
  PropList =
    [{successful, [ [{line, 1}]]},
     {failed,
      [[{line, 1},
        {status, {error, {error, {assertion_failed, ErrorInfo}, []}}}]]},
     {cancelled,  [ [{line, 1}] ]}],
  [ ?_assertMatch([{'passed-test', source, 1,  _},
                   {'failed-test', source, 1, _},
                   {'cancelled-test', source, 1, _}],
                  format_results(source, orddict:from_list(PropList)))
  ].

to_str_test_() ->
  [?_assertEqual("foo",         lists:flatten(to_str(foo))),
   ?_assertEqual("\"foo\"",     lists:flatten(to_str("foo"))),
   ?_assertEqual("[{foo,123}]", lists:flatten(to_str([{foo,123}])))
  ].

reason_to_props_test_() ->
  [?_assertEqual({expected, value}, reason_to_props(assertion_failed)),
   ?_assertEqual({undefined, undefined}, reason_to_props(foooo))
  ].

%%%_* Test helpers -------------------------------------------------------------

run_tests_common() ->
  Ref      = make_ref(),
  Listener = self(),
  Pid      = spawn(fun() -> Listener ! do_run_tests(Ref, Listener, 1) end),
  Pid ! {start, Ref},
  assert_receive({start, Ref}),
  {Ref, Pid}.

assert_receive(Expected) ->
  ?assertEqual(Expected, receive Expected -> Expected end).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
