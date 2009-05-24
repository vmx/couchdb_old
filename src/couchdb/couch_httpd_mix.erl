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


-record(mix_get_req, {
    external = nil,
    view = nil,
    list = nil
}).

-record(mix_settings_view, {
    name = nil,
    query_ = nil
}).

-record(mix_settings_external, {
    name = nil,
    query_ = nil,
    include_docs = false
}).

-record(mix_settings_list, {
    name = nil,
    query_ = nil,
    view = nil
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

% example request
% curl 'http://localhost:5984/geodata/_mix/normal?view=\{"name":"all","query":\{"limit":"10000"\}\}&external=\{"name":"geo","query":\{"q":"\{\"geom\":\"location\",\"bbox\":\[0,50,11,51\]\}"\}\}'
% http://localhost:5984/geodata/_mix/normal?view={"name":"all","query":{"limit":"11"}}&external={"name":"geo","query":{"q":"{\"geom\":\"location\",\"bbox\":[0,50,11,51]}"}}
% curl 'http://localhost:5984/geodata/_mix/normal?list=\{"name":"geojson","view":"all","query":\{"limit":"100"\}\}&external=\{"name":"geo","query":\{"q":"\{\"geom\":\"location\",\"bbox\":\[0,50,11,51\]\}"\}\}'
handle_mix_req(#httpd{method='GET',
        path_parts=[_Db, _Mix, DesignName]}=Req, Db) ->
    QueryList = couch_httpd:qs(Req),
    ?LOG_DEBUG("QueryList: ~p", [QueryList]),

    #mix_get_req{
        external = ExternalProps,
        view = ViewProps,
        list = ListProps
    } = parse_mix_get_req(QueryList),
    ?LOG_DEBUG("external, view, list: ~p ~p ~p", [ExternalProps, ViewProps,
                                                  ListProps]),

    if
        ViewProps /= nil ->
            #mix_settings_view{
                name = ViewName,
                query_ = {ViewQuery}
            } = parse_mix_settings_view(ViewProps),
            ViewArgs = kvlist_b2l(ViewQuery),
            design_doc_view(Req, Db, DesignName, ViewName, nil, ViewArgs,
                            ExternalProps);
        ListProps /= nil ->
            #mix_settings_list{
                name = ListName,
                query_ = {ListQuery},
                view = ListViewName
            } = parse_mix_settings_list(ListProps),
            ListArgs = kvlist_b2l(ListQuery),
            ?LOG_DEBUG("ListQuery: ~p", [ListQuery]),

            DesignId = <<"_design/", DesignName/binary>>,
            #doc{body={Props}} = couch_httpd_db:couch_doc_open(Db, DesignId,
                                                               nil, []),
            Lang = proplists:get_value(<<"language">>, Props, <<"javascript">>),
            ListSrc = couch_httpd_show:get_nested_json_value({Props},
                                                     [<<"lists">>, ListName]),
            send_view_list_response(Lang, ListSrc, ListViewName, DesignId, Req,
                                    Db, nil, ListArgs, ExternalProps);
        true ->
            ?LOG_ERROR("view or list parameter is missing.", [])
    end;

% example request:
% curl -d '{"design": "first", "view": {"name": "all", "query": {"limit": 11}}, "external": {"name": "geo", "query": {"q": {"geom": "loc", "inbbox": [0,-90,180,90]}}}}' http://localhost:5984/geodata/_mix
%curl -d '{"design": "normal", "view": {"name": "all", "query": {"limit": "11", "include_docs": "true"}}, "external": {"name": "minimal", "query": {"q": "q3"}, "include_docs": true}}' http://localhost:5984/foo/_mix
%curl -d '{"design": "normal", "view": {"name": "all", "query": {"limit": "20000"}}, "external": {"name": "geo", "query": {"q": "{\"geom\":\"location\",\"bbox\":[5,45,12,50]}"}, "include_docs": false}}' http://localhost:5984/geodata/_mix
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
    ?LOG_DEBUG("ExternalProps: ~p", [ExternalProps]),
    % nil == Keys
    design_doc_view(Req, Db, DesignDoc, ViewName, nil, ViewArgs,
        ExternalProps);

handle_mix_req(Req, _Db) ->
    send_method_not_allowed(Req, "GET,POST").

parse_mix_get_req(GetReq) ->
    lists:foldl(fun({Key, Value}, Args) ->
        {ValueDecoded} = ?JSON_DECODE(Value),
        case {Key, Value} of
        {"", _} ->
            Args;
        {"external", Value} ->
            Args#mix_get_req{external=ValueDecoded};
        {"view", Value} ->
            Args#mix_get_req{view=ValueDecoded};
        {"list", Value} ->
            Args#mix_get_req{list=ValueDecoded}
        end
     end, #mix_get_req{}, GetReq).

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

parse_mix_settings_list(Settings) ->
    lists:foldl(fun({Key,Value}, Args) ->
        case {Key, Value} of
        {"", _} ->
            Args;
        {<<"name">>, Value} ->
            Args#mix_settings_list{name=Value};
        {<<"query">>, Value} ->
            Args#mix_settings_list{query_=Value};
        {<<"view">>, Value} ->
            Args#mix_settings_list{view=Value}
	end
    end, #mix_settings_list{}, Settings).


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

    Response = process_external(Req, Db, ExternalName, ExternalQuery),
    #extern_resp_args{
        data = Data
    } = couch_httpd_external:parse_external_response(Response),
    ExternalDocIds = ?JSON_DECODE(Data),
    %?LOG_DEBUG("ExternalDocIds: ~p", [ExternalDocIds]),
    ?LOG_DEBUG("ExternalDocIds size: ~p", [length(ExternalDocIds)]),
    ExternalDocIdsSet = sets:from_list(ExternalDocIds),

    fun({{Key, DocId}, Value}, OffsetReds,
                      {AccLimit, AccSkip, Resp, AccRevRows}) ->
        %IncludeDoc = ?JSON_DECODE(Data),
        %IncludeDoc = true,
        %IncludeDoc = lists:member(DocId, ExternalDocIds),
        IncludeDoc = sets:is_element(DocId, ExternalDocIdsSet),
        case IncludeDoc of
        false ->
            Fun({{Key, DocId}, Value}, OffsetReds,
                {AccLimit, 1, Resp, AccRevRows});
        _ ->
            Fun({{Key, DocId}, Value}, OffsetReds,
                {AccLimit, AccSkip, Resp, AccRevRows})
    end
end.




send_view_list_response(Lang, ListSrc, ViewName, DesignId, Req, Db, Keys,
                        ViewArgs, ExternalProps) ->
    #view_query_args{
        stale = Stale,
        reduce = Reduce
    %} = QueryArgs = couch_httpd_view:parse_view_query(Req, nil, nil, true),
    } = QueryArgs = couch_httpd_view:parse_view_query_list(ViewArgs),
    case couch_view:get_map_view(Db, DesignId, ViewName, Stale) of
    {ok, View, Group} ->    
        output_map_list(Req, Lang, ListSrc, View, Group, Db, QueryArgs, Keys, ExternalProps);
    {not_found, _Reason} ->
        case couch_view:get_reduce_view(Db, DesignId, ViewName, Stale) of
        {ok, ReduceView, Group} ->
            couch_httpd_view:parse_view_query(Req, Keys, true, true), % just for validation
            case Reduce of
            false ->
                MapView = couch_view:extract_map_view(ReduceView),
                output_map_list(Req, Lang, ListSrc, MapView, Group, Db, QueryArgs, Keys, ExternalProps);
            _ ->
                couch_httpd_show:output_reduce_list(Req, Lang, ListSrc, ReduceView, Group, Db, QueryArgs, Keys)
            end;
        {not_found, Reason} ->
            throw({not_found, Reason})
        end
    end.

output_map_list(#httpd{mochi_req=MReq}=Req, Lang, ListSrc, View, Group, Db, QueryArgs, nil, ExternalProps) ->
    #view_query_args{
        limit = Limit,
        direction = Dir,
        skip = SkipCount,
        start_key = StartKey,
        start_docid = StartDocId
    } = QueryArgs,
    {ok, RowCount} = couch_view:get_row_count(View),
    Start = {StartKey, StartDocId},
    Headers = MReq:get(headers),
    Hlist = mochiweb_headers:to_list(Headers),
    Accept = proplists:get_value('Accept', Hlist),
    CurrentEtag = couch_httpd_view:view_group_etag(Group, {Lang, ListSrc, Accept}),
    couch_httpd:etag_respond(Req, CurrentEtag, fun() ->
        % get the os process here
        % pass it into the view fold with closures
        {ok, QueryServer} = couch_query_servers:start_view_list(Lang, ListSrc),

        StartListRespFun = couch_httpd_show:make_map_start_resp_fun(QueryServer, Req, Db, CurrentEtag),
        SendListRowFun = couch_httpd_show:make_map_send_row_fun(QueryServer, Req),
    
        FoldlFun = make_view_fold_fun(Req, QueryArgs, CurrentEtag, Db, RowCount,
            #view_fold_helper_funs{
                reduce_count = fun couch_view:reduce_to_count/1,
                start_response = StartListRespFun,
                send_row = SendListRowFun
            }, ExternalProps),
        FoldAccInit = {Limit, SkipCount, undefined, []},
        FoldResult = couch_view:fold(View, Start, Dir, FoldlFun, FoldAccInit),
        couch_httpd_show:finish_list(Req, Db, QueryServer, CurrentEtag, FoldResult, StartListRespFun, RowCount)
    end).


kvlist_b2l(KVList) ->
    lists:map(fun({Key, Value}) ->
        {binary_to_list(Key), binary_to_list(Value)}
    end,
    KVList).
