(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *   INRIA, CNRS and contributors - Copyright 1999-2018       *)
(* <O___,, *       (see CREDITS file for the list of authors)           *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

(************************************************************************)
(* Coq Language Server Protocol                                         *)
(* Copyright 2019 MINES ParisTech -- Dual License LGPL 2.1 / GPL3+      *)
(* Copyright 2019-2023 Inria      -- Dual License LGPL 2.1 / GPL3+      *)
(* Written by: Emilio J. Gallego Arias                                  *)
(************************************************************************)

(** This is the platform-independent code for the implementation of the Flèche
    LSP interface, BEWARE of deps, this must be able to run in a Web Worker
    context *)

module F = Format
module J = Yojson.Safe
module U = Yojson.Safe.Util

let field name dict =
  try List.(assoc name dict)
  with Not_found ->
    raise (U.Type_error ("field " ^ name ^ " not found", `Assoc dict))

let int_field name dict = U.to_int (field name dict)
let dict_field name dict = U.to_assoc (field name dict)
let list_field name dict = U.to_list (field name dict)
let string_field name dict = U.to_string (field name dict)
let ofield name dict = List.(assoc_opt name dict)
let ostring_field name dict = Option.map U.to_string (ofield name dict)

module LIO = Lsp.Io
module LSP = Lsp.Base

module Helpers = struct
  (* helpers; fix to have better errors on wrong protocol code *)
  let get_uri params =
    let document =
      field "textDocument" params
      |> Lsp.Doc.TextDocumentIdentifier.of_yojson |> Result.get_ok
    in
    let Lsp.Doc.TextDocumentIdentifier.{ uri } = document in
    uri

  let get_uri_oversion params =
    let document =
      field "textDocument" params
      |> Lsp.Doc.OVersionedTextDocumentIdentifier.of_yojson |> Result.get_ok
    in
    let Lsp.Doc.OVersionedTextDocumentIdentifier.{ uri; version } = document in
    (uri, version)

  let get_uri_version params =
    let document =
      field "textDocument" params
      |> Lsp.Doc.VersionedTextDocumentIdentifier.of_yojson |> Result.get_ok
    in
    let Lsp.Doc.VersionedTextDocumentIdentifier.{ uri; version } = document in
    (uri, version)

  let get_position params =
    let pos = dict_field "position" params in
    let line, character = (int_field "line" pos, int_field "character" pos) in
    (line, character)
end

(** LSP loop internal state: mainly the data needed to create a new document. In
    particular, we need:

    - the core root state of Coq
    - the list of workspaces configured

    Our notion of workspace corresponds to the usual notion in Coq of "theory",
    (that is to say, a [_CoqProject] or [(coq.theory ...)] declaration), which
    is to say a set of files that share a common logical path and logical
    mappings to other theories.

    [_CoqProject]-based workspaces need an explicit global flag setup, whereas
    dune-based ones declare dependencies on other workspaces. *)
module State = struct
  type t =
    { cmdline : Coq.Workspace.CmdLine.t
    ; root_state : Coq.State.t
    ; workspaces : (string * Coq.Workspace.t) list
    }

  open Lsp.Workspace

  let add_workspace state { WorkspaceFolder.uri; _ } =
    let dir = Lang.LUri.File.to_string_file uri in
    let { cmdline; workspaces; _ } = state in
    let ws = Coq.Workspace.guess ~debug:false ~cmdline ~dir in
    { state with workspaces = (dir, ws) :: workspaces }

  let del_workspace state { WorkspaceFolder.uri; _ } =
    let dir = Lang.LUri.File.to_string_file uri in
    { state with workspaces = List.remove_assoc dir state.workspaces }

  let is_in_dir ~dir ~file = CString.is_prefix dir file

  let workspace_of_uri ~uri ~state =
    let { root_state; workspaces; _ } = state in
    let file = Lang.LUri.File.to_string_file uri in
    match List.find_opt (fun (dir, _) -> is_in_dir ~dir ~file) workspaces with
    | None ->
      LIO.logMessage ~lvl:1 ~message:("file not in workspace: " ^ file);
      (root_state, snd (List.hd workspaces))
    | Some (_, workspace) -> (root_state, workspace)
end

let do_changeWorkspaceFolders ~ofn:_ ~state params =
  let open Lsp.Workspace in
  let { DidChangeWorkspaceFoldersParams.event } =
    DidChangeWorkspaceFoldersParams.of_yojson (`Assoc params) |> Result.get_ok
  in
  let { WorkspaceFoldersChangeEvent.added; removed } = event in
  let state = List.fold_left State.add_workspace state added in
  let state = List.fold_left State.del_workspace state removed in
  state

(* main request module with [answer, postpone, cancel, serve] methods, basically
   IO + glue with the doc_manager *)
module Rq : sig
  module Action : sig
    type t =
      | Immediate of Request.R.t
      | Data of Request.Data.t

    val now : Request.R.t -> t
    val error : int * string -> t
  end

  val serve : ofn:(J.t -> unit) -> id:int -> Action.t -> unit
  val cancel : ofn:(J.t -> unit) -> code:int -> message:string -> int -> unit

  val serve_postponed :
    ofn:(J.t -> unit) -> doc:Fleche.Doc.t -> Int.Set.t -> unit
end = struct
  (* Answer a request, private *)
  let answer ~ofn ~id result =
    (match result with
    | Result.Ok result -> LSP.mk_reply ~id ~result
    | Error (code, message) -> LSP.mk_request_error ~id ~code ~message)
    |> ofn

  (* private to the Rq module, just used not to retrigger canceled requests *)
  let _rtable : (int, Request.Data.t) Hashtbl.t = Hashtbl.create 673

  let postpone ~id (pr : Request.Data.t) =
    if Fleche.Debug.request_delay then
      LIO.trace "request" ("postponing rq : " ^ string_of_int id);
    Hashtbl.add _rtable id pr

  (* Consumes a request, if alive, it answers mandatorily *)
  let consume_ ~ofn ~f id =
    match Hashtbl.find_opt _rtable id with
    | Some pr ->
      Hashtbl.remove _rtable id;
      f pr |> answer ~ofn ~id
    | None ->
      LIO.trace "can't consume cancelled request: " (string_of_int id);
      ()

  let cancel ~ofn ~code ~message id : unit =
    (* fail the request, do cleanup first *)
    let f pr =
      let () =
        let request = Request.Data.dm_request pr in
        Doc_manager.Request.remove { id; request }
      in
      Error (code, message)
    in
    consume_ ~ofn ~f id

  let debug_serve id pr =
    if Fleche.Debug.request_delay then
      LIO.trace "serving"
        (Format.asprintf "rq: %d | %a" id Request.Data.data pr)

  let serve_postponed ~ofn ~doc id =
    let f pr =
      debug_serve id pr;
      Request.Data.serve ~doc pr
    in
    consume_ ~ofn ~f id

  let query ~ofn ~id (pr : Request.Data.t) =
    let request = Request.Data.dm_request pr in
    match Doc_manager.Request.add { id; request } with
    | Cancel ->
      let code = -32802 in
      let message = "Document is not ready" in
      Error (code, message) |> answer ~ofn ~id
    | Now doc ->
      debug_serve id pr;
      Request.Data.serve ~doc pr |> answer ~ofn ~id
    | Postpone -> postpone ~id pr

  module Action = struct
    type t =
      | Immediate of Request.R.t
      | Data of Request.Data.t

    let now r = Immediate r
    let error (code, msg) = now (Error (code, msg))
  end

  let serve ~ofn ~id action =
    match action with
    | Action.Immediate r -> answer ~ofn ~id r
    | Action.Data p -> query ~ofn ~id p

  let serve_postponed ~ofn ~doc rl = Int.Set.iter (serve_postponed ~ofn ~doc) rl
end

(***********************************************************************)
(* Start of protocol handlers: document notifications                  *)

let do_open ~ofn ~(state : State.t) params =
  let document =
    field "textDocument" params
    |> Lsp.Doc.TextDocumentItem.of_yojson |> Result.get_ok
  in
  let Lsp.Doc.TextDocumentItem.{ uri; version; text; _ } = document in
  let root_state, workspace = State.workspace_of_uri ~uri ~state in
  Doc_manager.create ~ofn ~root_state ~workspace ~uri ~raw:text ~version

let do_change ~ofn params =
  let uri, version = Helpers.get_uri_version params in
  let changes = List.map U.to_assoc @@ list_field "contentChanges" params in
  match changes with
  | [] ->
    LIO.trace "do_change" "no change in changes? ignoring";
    ()
  | _ :: _ :: _ ->
    LIO.trace "do_change"
      "more than one change unsupported due to sync method, ignoring";
    ()
  | change :: _ ->
    let raw = string_field "text" change in
    let invalid_rq = Doc_manager.change ~ofn ~uri ~version ~raw in
    let code = -32802 in
    let message = "Request got old in server" in
    Int.Set.iter (Rq.cancel ~ofn ~code ~message) invalid_rq

let do_close ~ofn:_ params =
  let uri = Helpers.get_uri params in
  Doc_manager.close ~uri

let do_trace params =
  let trace = string_field "value" params in
  match LIO.TraceValue.of_string trace with
  | Ok t -> LIO.set_trace_value t
  | Error e -> LIO.trace "trace" ("invalid value: " ^ e)

(***********************************************************************)
(* Start of protocol handlers: document requests                       *)

let do_shutdown = Rq.Action.now (Ok `Null)

let do_position_request ~postpone ~params ~handler =
  let uri, version = Helpers.get_uri_oversion params in
  let point = Helpers.get_position params in
  Rq.Action.Data
    (Request.Data.PosRequest { uri; handler; point; version; postpone })

let do_hover = do_position_request ~postpone:false ~handler:Rq_hover.hover

(* We get the format from the params *)
let get_pp_format_from_config () =
  match !Fleche.Config.v.pp_type with
  | 0 -> Rq_goals.Str
  | 1 -> Rq_goals.Pp
  | v ->
    LIO.trace "get_pp_format_from_config"
      ("unknown output parameter: " ^ string_of_int v);
    Rq_goals.Str

let get_pp_format params =
  match ostring_field "pp_format" params with
  | Some "Pp" -> Rq_goals.Pp
  | Some "Str" -> Rq_goals.Str
  | Some v ->
    LIO.trace "get_pp_format" ("error in parameter: " ^ v);
    get_pp_format_from_config ()
  | None -> get_pp_format_from_config ()

let do_goals ~params =
  let pp_format = get_pp_format params in
  let handler = Rq_goals.goals ~pp_format in
  do_position_request ~postpone:true ~handler ~params

let do_definition =
  do_position_request ~postpone:true ~handler:Rq_definition.request

let do_completion =
  do_position_request ~postpone:true ~handler:Rq_completion.completion

(* Requires the full document to be processed *)
let do_document_request ~params ~handler =
  let uri = Helpers.get_uri params in
  Rq.Action.Data (Request.Data.DocRequest { uri; handler })

let do_symbols = do_document_request ~handler:Rq_symbols.symbols
let do_document = do_document_request ~handler:Rq_document.request
let do_save_vo = do_document_request ~handler:Rq_save.request
let do_lens = do_document_request ~handler:Rq_lens.request

let do_cancel ~ofn ~params =
  let id = int_field "id" params in
  let code = -32800 in
  let message = "Cancelled by client" in
  Rq.cancel ~ofn ~code ~message id

(***********************************************************************)

(** LSP Init routine *)
exception Lsp_exit

let log_workspace (dir, w) =
  let message, extra = Coq.Workspace.describe w in
  LIO.trace "workspace" ("initialized " ^ dir) ~extra;
  LIO.logMessage ~lvl:3 ~message

let version () =
  let dev_version =
    match Build_info.V1.version () with
    | None -> "N/A"
    | Some bi -> Build_info.V1.Version.to_string bi
  in
  Format.asprintf "version %s, dev: %s, Coq version: %s, OS: %s" Version.server
    dev_version Coq_config.version Sys.os_type

module Init_effect = struct
  type t =
    | Success of (string * Coq.Workspace.t) list
    | Loop
    | Exit
end

let lsp_init_process ~ofn ~cmdline ~debug msg : Init_effect.t =
  match msg with
  | LSP.Message.Request { method_ = "initialize"; id; params } ->
    (* At this point logging is allowed per LSP spec *)
    let message =
      Format.asprintf "Initializing coq-lsp server %s" (version ())
    in
    LIO.logMessage ~lvl:3 ~message;
    let result, dirs = Rq_init.do_initialize ~params in
    Rq.Action.now (Ok result) |> Rq.serve ~ofn ~id;
    LIO.logMessage ~lvl:3 ~message:"Server initialized";
    (* Workspace initialization *)
    let debug = debug || !Fleche.Config.v.debug in
    let workspaces =
      List.map (fun dir -> (dir, Coq.Workspace.guess ~cmdline ~debug ~dir)) dirs
    in
    List.iter log_workspace workspaces;
    Success workspaces
  | LSP.Message.Request { id; _ } ->
    (* per spec *)
    LSP.mk_request_error ~id ~code:(-32002) ~message:"server not initialized"
    |> ofn;
    Loop
  | LSP.Message.Notification { method_ = "exit"; params = _ } -> Exit
  | LSP.Message.Notification _ ->
    (* We can't log before getting the initialize message *)
    Loop

(** Dispatching *)
let dispatch_notification ~ofn ~state ~method_ ~params : unit =
  match method_ with
  (* Lifecycle *)
  | "exit" -> raise Lsp_exit
  (* setTrace *)
  | "$/setTrace" -> do_trace params
  (* Document lifetime *)
  | "textDocument/didOpen" -> do_open ~ofn ~state params
  | "textDocument/didChange" -> do_change ~ofn params
  | "textDocument/didClose" -> do_close ~ofn params
  | "textDocument/didSave" -> Cache.save_to_disk ()
  (* Cancel Request *)
  | "$/cancelRequest" -> do_cancel ~ofn ~params
  (* NOOPs *)
  | "initialized" -> ()
  (* Generic handler *)
  | msg -> LIO.trace "no_handler" msg

let dispatch_state_notification ~ofn ~state ~method_ ~params : State.t =
  match method_ with
  (* Workspace *)
  | "workspace/didChangeWorkspaceFolders" ->
    do_changeWorkspaceFolders ~ofn ~state params
  | _ ->
    dispatch_notification ~ofn ~state ~method_ ~params;
    state

let dispatch_request ~method_ ~params : Rq.Action.t =
  match method_ with
  (* Lifecyle *)
  | "initialize" ->
    LIO.trace "dispatch_request" "duplicate initialize request! Rejecting";
    (* XXX what's the error code here *)
    Rq.Action.error (-32600, "Invalid Request: server already initialized")
  | "shutdown" -> do_shutdown
  (* Symbols and info about the document *)
  | "textDocument/completion" -> do_completion ~params
  | "textDocument/definition" -> do_definition ~params
  | "textDocument/documentSymbol" -> do_symbols ~params
  | "textDocument/hover" -> do_hover ~params
  | "textDocument/codeLens" -> do_lens ~params
  (* Proof-specific stuff *)
  | "proof/goals" -> do_goals ~params
  (* Proof-specific stuff *)
  | "coq/saveVo" -> do_save_vo ~params
  (* Coq specific stuff *)
  | "coq/getDocument" -> do_document ~params
  (* Generic handler *)
  | msg ->
    LIO.trace "no_handler" msg;
    Rq.Action.error (-32601, "method not found")

let dispatch_request ~ofn ~id ~method_ ~params =
  dispatch_request ~method_ ~params |> Rq.serve ~ofn ~id

let dispatch_message ~ofn ~state (com : LSP.Message.t) : State.t =
  match com with
  | Notification { method_; params } ->
    dispatch_state_notification ~ofn ~state ~method_ ~params
  | Request { id; method_; params } ->
    dispatch_request ~ofn ~id ~method_ ~params;
    state

(* Queue handling *)

(***********************************************************************)
(* The queue strategy is: we keep pending document checks in Doc_manager, they
   are only resumed when the rest of requests in the queue are served.

   Note that we should add a method to detect stale requests; maybe cancel them
   when a new edit comes. *)

type 'a cont =
  | Cont of 'a
  | Yield of 'a

let check_or_yield ~ofn ~state =
  match Doc_manager.Check.maybe_check ~ofn with
  | None -> Yield state
  | Some (ready, doc) ->
    let () = Rq.serve_postponed ~ofn ~doc ready in
    Cont state

let request_queue = Queue.create ()

let dispatch_or_resume_check ~ofn ~state =
  match Queue.peek_opt request_queue with
  | None ->
    (* This is where we make progress on document checking; kind of IDLE
       workqueue. *)
    Control.interrupt := false;
    check_or_yield ~ofn ~state
  | Some com ->
    (* TODO: optimize the queue? EJGA: I've found that VS Code as a client keeps
       the queue tidy by itself, so this works fine as now *)
    ignore (Queue.pop request_queue);
    LIO.trace "process_queue" ("Serving Request: " ^ LSP.Message.method_ com);
    (* We let Coq work normally now *)
    Control.interrupt := false;
    Cont (dispatch_message ~ofn ~state com)

(* Wrapper for the top-level call *)
let dispatch_or_resume_check ~ofn ~state =
  try Some (dispatch_or_resume_check ~ofn ~state) with
  | U.Type_error (msg, obj) ->
    LIO.trace_object msg obj;
    Some (Yield state)
  | Lsp_exit ->
    (* EJGA: Maybe remove Lsp_exit and have dispatch_or_resume_check return an
       action? *)
    None
  | exn ->
    (* Note: We should never arrive here from Coq, as every call to Coq should
       be wrapper in Coq.Protect. So hitting this codepath, is effectively a
       coq-lsp internal error and should be fixed *)
    let bt = Printexc.get_backtrace () in
    let iexn = Exninfo.capture exn in
    LIO.trace "process_queue"
      (if Printexc.backtrace_status () then "bt=true" else "bt=false");
    (* let method_name = LSP.Message.method_ com in *)
    (* LIO.trace "process_queue" ("exn in method: " ^ method_name); *)
    LIO.trace "print_exn [OCaml]" (Printexc.to_string exn);
    LIO.trace "print_exn [Coq  ]" Pp.(string_of_ppcmds CErrors.(iprint iexn));
    LIO.trace "print_bt  [OCaml]" bt;
    Some (Yield state)

let enqueue_message (com : LSP.Message.t) =
  if Fleche.Debug.sched_wakeup then
    LIO.trace "-> enqueue" (Format.asprintf "%.2f" (Unix.gettimeofday ()));
  (* TODO: this is the place to cancel pending requests that are invalid, and in
     general, to perform queue optimizations *)
  Queue.push com request_queue;
  Control.interrupt := true
