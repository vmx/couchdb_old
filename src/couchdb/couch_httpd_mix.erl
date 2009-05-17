% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License.  You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_httpd_mix).
-include("couch_db.hrl").

-export([handle_mix_req/2]).

-import(couch_httpd,[send_error/4,send_method_not_allowed/2]).

-record(mix_settings_view, {
    name = nil,
    query_ = nil
}).

-record(mix_settings_external, {
    name = nil,
    query_ = nil,
    include_docs = false
}).

process_external(HttpReq, Db, Name, Query) ->
    couch_external_manager:execute(binary_to_list(Name),
        json_req_obj(HttpReq, Db, Query)).

json_req_obj(#httpd{mochi_req=Req, 
               method=Verb,
               path_parts=Path,
               req_body=ReqBody
            }, Db, Query) ->
    %Body = case ReqBody of
    %    undefined -> Req:recv_body();
    %    Else -> Else
    %end,
    %ParsedForm = case Req:get_primary_header_value("content-type") of
    %    "application/x-www-form-urlencoded" ++ _ ->
    %        mochiweb_util:parse_qs(ReqBody);
    %    _ ->
    %        []
    %end,
    Headers = Req:get(headers),
    Hlist = mochiweb_headers:to_list(Headers),
    {ok, Info} = couch_db:get_db_info(Db),
    % add headers...
    {[{<<"info">>, {Info}},
        {<<"verb">>, Verb},
        {<<"path">>, Path},
        {<<"query">>, {Query}}]}.
%        {<<"headers">>, couch_httpd_external:to_json_terms(Hlist)},
%        {<<"body">>, Body},
%        {<<"form">>, couch_httpd_external:to_json_terms(ParsedForm)},
%        {<<"cookie">>, couch_httpd_external:to_json_terms(Req:parse_cookie())}}]}.

% example request:
% curl -d '{"design": "first", "view": {"name": "all", "query": {"limit": 11}}, "external": {"name": "geo", "query": {"q": {"geom": "loc", "inbbox": [0,-90,180,90]}}}}' http://localhost:5984/geodata/_mix
%curl -d '{"design": "normal", "view": {"name": "all", "query": {"limit": "11", "include_docs": "true"}}, "external": {"name": "minimal", "query": {"q": "q3"}, "include_docs": true}}' http://localhost:5984/foo/_mix
handle_mix_req(#httpd{method='POST'}=Req, Db) ->
    {Props} = couch_httpd:json_body(Req),
    DesignDoc = proplists:get_value(<<"design">>, Props),
    {ViewProps} = proplists:get_value(<<"view">>, Props, {}),
    #mix_settings_view{
        name = ViewName,
        query_ = {ViewQuery}
    } = parse_mix_settings_view(ViewProps),
    ViewArgs = lists:map(fun({Key, Value}) ->
            {binary_to_list(Key), binary_to_list(Value)}
         end,
         ViewQuery),

    {ExternalProps} = proplists:get_value(<<"external">>, Props, {}),
    % nil == Keys
    design_doc_view(Req, Db, DesignDoc, ViewName, nil, ViewArgs,
        ExternalProps);

handle_mix_req(Req, _Db) ->
    send_method_not_allowed(Req, "POST").

parse_mix_settings_view(Settings) ->
    lists:foldl(fun({Key,Value}, Args) ->
        case {Key, Value} of
        {"", _} ->
            Args;
        {<<"name">>, Value} ->
            Args#mix_settings_view{name=Value};
        {<<"query">>, Value} ->
            Args#mix_settings_view{query_=Value}
	end
    end, #mix_settings_view{}, Settings).

parse_mix_settings_external(Settings) ->
    lists:foldl(fun({Key,Value}, Args) ->
        case {Key, Value} of
        {"", _} ->
            Args;
        {<<"name">>, Value} ->
            Args#mix_settings_external{name=Value};
        {<<"query">>, Value} ->
            Args#mix_settings_external{query_=Value};
        {<<"include_docs">>, Value} ->
            Args#mix_settings_external{include_docs=Value}
	end
    end, #mix_settings_external{}, Settings).


design_doc_view(Req, Db, Id, ViewName, Keys, ViewArgs, ExternalProps) ->
    #view_query_args{
        stale = Stale,
        reduce = Reduce
    } = QueryArgs = couch_httpd_view:parse_view_query_list(ViewArgs),
    DesignId = <<"_design/", Id/binary>>,
    Result = case couch_view:get_map_view(Db, DesignId, ViewName, Stale) of
    {ok, View, Group} ->
        output_map_view(Req, View, Group, Db, QueryArgs, Keys, ExternalProps);
    {not_found, Reason} ->
        case couch_view:get_reduce_view(Db, DesignId, ViewName, Stale) of
        {ok, ReduceView, Group} ->
            couch_httpd_view:parse_view_query(Req, Keys, true), % just for validation
            case Reduce of
            false ->
                MapView = couch_view:extract_map_view(ReduceView),
                output_map_view(Req, MapView, Group, Db, QueryArgs, Keys,
                        ExternalProps);
            _ ->
                couch_httpd_view:output_reduce_view(Req, ReduceView, Group, QueryArgs, Keys)
            end;
        _ ->
            throw({not_found, Reason})
        end
    end,
    couch_stats_collector:increment({httpd, view_reads}),
    Result.

output_map_view(Req, View, Group, Db, QueryArgs, nil, ExternalProps) ->
    #view_query_args{
        limit = Limit,
        direction = Dir,
        skip = SkipCount,
        start_key = StartKey,
        start_docid = StartDocId
    } = QueryArgs,
    couch_httpd_view:validate_map_query(QueryArgs),
    CurrentEtag = couch_httpd_view:view_group_etag(Group),
    couch_httpd:etag_respond(Req, CurrentEtag, fun() -> 
        {ok, RowCount} = couch_view:get_row_count(View),
        Start = {StartKey, StartDocId},
        FoldlFun = make_view_fold_fun(Req, QueryArgs, CurrentEtag, Db,
                RowCount, #view_fold_helper_funs{
                reduce_count=fun couch_view:reduce_to_count/1}, ExternalProps),
        FoldAccInit = {Limit, SkipCount, undefined, []},
        FoldResult = couch_view:fold(View, Start, Dir, FoldlFun, FoldAccInit),
        couch_httpd_view:finish_view_fold(Req, RowCount, FoldResult)
    end).

make_view_fold_fun(Req, QueryArgs, Etag, Db,
        TotalViewCount, HelperFuns, ExternalProps) ->
    Fun = couch_httpd_view:make_view_fold_fun(Req, QueryArgs, Etag, Db, TotalViewCount, HelperFuns),
    #mix_settings_external{
        name = ExternalName,
        query_ = {ExternalQuery},
        include_docs = IncludeDocs
    } = parse_mix_settings_external(ExternalProps),

    %Response = process_external(Req, Db, ExternalName, ExternalQuery),
    %#extern_resp_args{
    %    data = Data
    %} = couch_httpd_external:parse_external_response(Response),
    %?LOG_DEBUG("Response: ~p", [Data]),

    fun({{Key, DocId}, Value}, OffsetReds,
                      {AccLimit, AccSkip, Resp, AccRevRows}) ->
        %IncludeDoc = ?JSON_DECODE(Data),
        IncludeDoc = true,
        case IncludeDoc of
        false ->
            Fun({{Key, DocId}, Value}, OffsetReds,
                {AccLimit, 1, Resp, AccRevRows});
        _ ->
            Fun({{Key, DocId}, Value}, OffsetReds,
                {AccLimit, AccSkip, Resp, AccRevRows})
    end
end.
