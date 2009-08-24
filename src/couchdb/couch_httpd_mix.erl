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

-record(mix_settings_external, {
    name = nil,
    query_ = nil
}).

process_external(HttpReq, Db, Name) ->
    couch_external_manager:execute(binary_to_list(Name),
        couch_httpd_external:json_req_obj(HttpReq, Db)).

% example request
% http://localhost:5984/geodata/_mix/normal/_external/geo/_list/geojson/all?limit=11&geom=location&bbox=0,50,11,51
% http://localhost:5984/geodata3/_mix/normal/_list/geojson_nobbox/all/_external/geo/normal?limit=11&geom=loc&bbox=0,50,11,51
% _external/_list intersection
handle_mix_req(#httpd{method='GET',
        path_parts=[_Db, _Mix, DesignName, <<"_list">>, ListName, ViewName,
                    _External, ExternalName | _ExternalPath]}=Req, Db) ->

    QueryList = couch_httpd:qs(Req),
    ExternalProps = #mix_settings_external{name=ExternalName,
                                           query_=QueryList},
    DesignId = <<"_design/", DesignName/binary>>,
    #doc{body={Props}} = couch_httpd_db:couch_doc_open(Db, DesignId, nil, []),
    Lang = proplists:get_value(<<"language">>, Props, <<"javascript">>),
    ListSrc = couch_util:get_nested_json_value({Props}, [<<"lists">>,
                                                               ListName]),
    send_view_list_response(Lang, ListSrc, ViewName, DesignId, Req, Db, nil,
                            ExternalProps);

% http://localhost:5984/geodata3/_mix/_external/geo/normal/_view/normal/all?limit=11&geom=loc&bbox=0,50,11,51
% http://localhost:5984/geodata3/_mix/normal/_view/all/_external/geo/normal?limit=11&geom=loc&bbox=0,50,11,51
% _external/_view intersection
handle_mix_req(#httpd{method='GET',
        path_parts=[_Db, _Mix, DesignName, <<"_view">>, ViewName,
                    _External, ExternalName | _ExternalPath]}=Req, Db) ->

    QueryList = couch_httpd:qs(Req),
    ExternalProps = #mix_settings_external{name=ExternalName,
                                           query_=QueryList},

    design_doc_view(Req, Db, DesignName, ViewName, nil, ExternalProps);

handle_mix_req(Req, _Db) ->
    send_method_not_allowed(Req, "GET").


design_doc_view(Req, Db, Id, ViewName, Keys, ExternalProps) ->
    DesignId = <<"_design/", Id/binary>>,
    Stale = couch_httpd_view:get_stale_type(Req),
    Reduce = couch_httpd_view:get_reduce_type(Req),
    Result = case couch_view:get_map_view(Db, DesignId, ViewName, Stale) of
    {ok, View, Group} ->
        QueryArgs = couch_httpd_view:parse_view_params(Req, Keys, map),
        output_map_view(Req, View, Group, Db, QueryArgs, Keys, ExternalProps);
    {not_found, Reason} ->
        case couch_view:get_reduce_view(Db, DesignId, ViewName, Stale) of
        {ok, ReduceView, Group} ->
            case Reduce of
            false ->
                QueryArgs = couch_httpd_view:parse_view_params(Req, Keys, red_map),
                MapView = couch_view:extract_map_view(ReduceView),
                output_map_view(Req, MapView, Group, Db, QueryArgs, Keys, ExternalProps);
            _ ->
                QueryArgs = couch_httpd_view:parse_view_params(Req, Keys, reduce),
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
    CurrentEtag = couch_httpd_view:view_group_etag(Group, Db),
    couch_httpd:etag_respond(Req, CurrentEtag, fun() -> 
        {ok, RowCount} = couch_view:get_row_count(View),
        Start = {StartKey, StartDocId},
        FoldlFun = make_view_fold_fun(Req, QueryArgs, CurrentEtag, Db,
                RowCount, #view_fold_helper_funs{
                    reduce_count=fun couch_view:reduce_to_count/1},
                ExternalProps),
        FoldAccInit = {Limit, SkipCount, undefined, [], nil},
        FoldResult = couch_view:fold(View, Start, Dir, FoldlFun, FoldAccInit),
        couch_httpd_view:finish_view_fold(Req, RowCount, FoldResult)
    end).


make_view_fold_fun(Req, QueryArgs, Etag, Db,
        TotalViewCount, HelperFuns, ExternalProps) ->
    Fun = couch_httpd_view:make_view_fold_fun(Req, QueryArgs, Etag, Db,
                                              TotalViewCount, HelperFuns),
    #mix_settings_external{
        name = ExternalName
    } = ExternalProps,

    Response = process_external(Req, Db, ExternalName),
    #extern_resp_args{
        data = Data
    } = couch_httpd_external:parse_external_response(Response),
    ExternalDocIds = ?JSON_DECODE(Data),
    ?LOG_DEBUG("ExternalDocIds: ~p", [length(ExternalDocIds)]),
    ExternalDocIdsSet = sets:from_list(ExternalDocIds),

    fun({{Key, DocId}, Value}, OffsetReds, {AccLimit, AccSkip, Resp, RowFunAcc,
                                            OffsetAcc}) ->
        IncludeDoc = sets:is_element(DocId, ExternalDocIdsSet),
        case IncludeDoc of
        false ->
            Fun({{Key, DocId}, Value}, OffsetReds,
                {AccLimit, 1, Resp, RowFunAcc, OffsetAcc});
        _ ->
            Fun({{Key, DocId}, Value}, OffsetReds,
                {AccLimit, AccSkip, Resp, RowFunAcc, OffsetAcc})
    end
end.


send_view_list_response(Lang, ListSrc, ViewName, DesignId, Req, Db, Keys,
                        ExternalProps) ->
    Stale = couch_httpd_view:get_stale_type(Req),
    Reduce = couch_httpd_view:get_reduce_type(Req),
    case couch_view:get_map_view(Db, DesignId, ViewName, Stale) of
    {ok, View, Group} ->    
        QueryArgs = couch_httpd_view:parse_view_params(Req, Keys, map),
        output_map_list(Req, Lang, ListSrc, View, Group, Db, QueryArgs, Keys,
                        ExternalProps);
    {not_found, _Reason} ->
        case couch_view:get_reduce_view(Db, DesignId, ViewName, Stale) of
        {ok, ReduceView, Group} ->
            case Reduce of
            false ->
                QueryArgs = couch_httpd_view:parse_view_params(
                    Req, Keys, map_red
                ),
                MapView = couch_view:extract_map_view(ReduceView),
                output_map_list(Req, Lang, ListSrc, MapView, Group, Db,
                                QueryArgs, Keys, ExternalProps);
            _ ->
                QueryArgs = couch_httpd_view:parse_view_params(
                    Req, Keys, reduce
                ),
                couch_httpd_show:output_reduce_list(
                    Req, Lang, ListSrc, ReduceView, Group, Db, QueryArgs, Keys
                )
            end;
        {not_found, Reason} ->
            throw({not_found, Reason})
        end
    end.

output_map_list(#httpd{mochi_req=MReq, user_ctx=UserCtx}=Req, Lang, ListSrc, View, Group, Db, QueryArgs, nil, ExternalProps) ->
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
    CurrentEtag = couch_httpd_view:view_group_etag(Group, Db, {Lang, ListSrc, Accept, UserCtx}),
    couch_httpd:etag_respond(Req, CurrentEtag, fun() ->
        % get the os process here
        % pass it into the view fold with closures
        {ok, QueryServer} = couch_query_servers:start_view_list(Lang, ListSrc),

        StartListRespFun = couch_httpd_show:make_map_start_resp_fun(QueryServer, Db),
        SendListRowFun = couch_httpd_show:make_map_send_row_fun(QueryServer),

        FoldlFun = make_view_fold_fun(Req, QueryArgs, CurrentEtag, Db, RowCount,
            #view_fold_helper_funs{
                reduce_count = fun couch_view:reduce_to_count/1,
                start_response = StartListRespFun,
                send_row = SendListRowFun
            }, ExternalProps),
        FoldAccInit = {Limit, SkipCount, undefined, [], nil},
        {ok, FoldResult} = couch_view:fold(View, Start, Dir, FoldlFun, FoldAccInit),
        couch_httpd_show:finish_list(Req, QueryServer, CurrentEtag, FoldResult, StartListRespFun, RowCount)
    end).

