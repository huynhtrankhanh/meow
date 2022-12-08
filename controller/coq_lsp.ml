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
(* Copyright 2019-2022 Inria      -- Dual License LGPL 2.1 / GPL3+      *)
(* Written by: Emilio J. Gallego Arias                                  *)
(************************************************************************)

module F = Format
module J = Yojson.Safe
module U = Yojson.Safe.Util

let int_field name dict = U.to_int List.(assoc name dict)
let dict_field name dict = U.to_assoc List.(assoc name dict)
let list_field name dict = U.to_list List.(assoc name dict)
let string_field name dict = U.to_string List.(assoc name dict)

(* Conditionals *)
let _option_empty x =
  match x with
  | None -> true
  | Some _ -> false

let option_cata f d x =
  match x with
  | None -> d
  | Some x -> f x

let option_default x d =
  match x with
  | None -> d
  | Some x -> x

let oint_field name dict = option_cata U.to_int 0 List.(assoc_opt name dict)
let ostring_field name dict = Option.map U.to_string (List.assoc_opt name dict)

let odict_field name dict =
  option_default
    U.(to_option to_assoc (option_default List.(assoc_opt name dict) `Null))
    []

module TraceValue = struct
  type t =
    | Off
    | Messages
    | Verbose

  let parse = function
    | "messages" -> Messages
    | "verbose" -> Verbose
    | "off" -> Off
    | _ -> raise (Invalid_argument "TraceValue.parse")

  let to_string = function
    | Off -> "off"
    | Messages -> "messages"
    | Verbose -> "verbose"
end

module LIO = Lsp.Io
module Log = Lsp.Log
module LSP = Lsp.Base

(* Request Handling: The client expects a reply *)
module CoqLspOption = struct
  type t = [%import: Fleche.Config.t] [@@deriving yojson]
end

let do_client_options coq_lsp_options =
  Log.log_error "init" "custom client options:";
  Log.log_object "init" (`Assoc coq_lsp_options);
  match CoqLspOption.of_yojson (`Assoc coq_lsp_options) with
  | Ok v -> Fleche.Config.v := v
  | Error _msg -> ()

let do_initialize ofmt ~id params =
  let coq_lsp_options = odict_field "initializationOptions" params in
  do_client_options coq_lsp_options;
  let client_capabilities = odict_field "capabilities" params in
  Log.log_error "init" "client capabilities:";
  Log.log_object "init" (`Assoc client_capabilities);
  let trace =
    ostring_field "trace" params |> option_cata TraceValue.parse TraceValue.Off
  in
  Log.log_error "init" ("trace: " ^ TraceValue.to_string trace);
  let capabilities =
    [ ("textDocumentSync", `Int 1)
    ; ("documentSymbolProvider", `Bool true)
    ; ("hoverProvider", `Bool true)
    ; ("completionProvider", `Assoc [])
    ; ("codeActionProvider", `Bool false)
    ]
  in
  let msg =
    LSP.mk_reply ~id
      ~result:
        (`Assoc
          [ ("capabilities", `Assoc capabilities)
          ; ( "serverInfo"
            , `Assoc
                [ ("name", `String "coq-lsp (C) Inria 2022")
                ; ("version", `String "0.1+alpha")
                ] )
          ])
  in
  LIO.send_json ofmt msg

let do_shutdown ofmt ~id =
  let msg = LSP.mk_reply ~id ~result:`Null in
  LIO.send_json ofmt msg

let doc_table : (string, Fleche.Doc.t) Hashtbl.t = Hashtbl.create 39

let lsp_of_diags ~uri ~version diags =
  List.map
    (fun { Fleche.Types.Diagnostic.range; severity; message; extra = _ } ->
      (range, severity, message, None))
    diags
  |> LSP.mk_diagnostics ~uri ~version

(* Notification handling; reply is optional / asynchronous *)
let do_check_text ofmt ~state ~doc =
  let _, _, _, fb_queue = state in
  let doc = Fleche.Doc.check ~ofmt ~doc ~fb_queue in
  Hashtbl.replace doc_table doc.uri doc;
  let diags = lsp_of_diags ~uri:doc.uri ~version:doc.version doc.diags in
  LIO.send_json ofmt @@ diags

let do_open ofmt ~state params =
  let document = dict_field "textDocument" params in
  let uri, version, contents =
    ( string_field "uri" document
    , int_field "version" document
    , string_field "text" document )
  in
  let doc = Fleche.Doc.create ~state ~uri ~contents ~version in
  (match Hashtbl.find_opt doc_table uri with
  | None -> ()
  | Some _ ->
    Log.log_error "do_open" ("file " ^ uri ^ " not properly closed by client"));
  Hashtbl.add doc_table uri doc;
  do_check_text ofmt ~state ~doc

let check_completed dict =
  let params = odict_field "params" dict in
  let document = dict_field "textDocument" params in
  let uri = string_field "uri" document in
  let doc = Hashtbl.find doc_table uri in
  doc.completed = Yes

let do_change ofmt ~state params =
  let document = dict_field "textDocument" params in
  let uri, version =
    (string_field "uri" document, int_field "version" document)
  in
  Log.log_error "checking file" (uri ^ " / version: " ^ string_of_int version);
  let changes = List.map U.to_assoc @@ list_field "contentChanges" params in
  match changes with
  | [] -> ()
  | _ :: _ :: _ ->
    Log.log_error "do_change"
      "more than one change unsupported due to sync method";
    assert false
  | change :: _ ->
    let text = string_field "text" change in
    let doc = Hashtbl.find doc_table uri in
    let doc =
      (* Note that we can restart the checking with the same version! *)
      if version > doc.version then Fleche.Doc.bump_version ~version ~text doc
      else doc
    in
    do_check_text ofmt ~state ~doc

let do_close _ofmt params =
  let document = dict_field "textDocument" params in
  let doc_file = string_field "uri" document in
  Hashtbl.remove doc_table doc_file

let grab_doc params =
  let document = dict_field "textDocument" params in
  let doc_file = string_field "uri" document in
  let doc = Hashtbl.(find doc_table doc_file) in
  (doc_file, doc)

let mk_syminfo file (name, _path, kind, pos) : J.t =
  `Assoc
    [ ("name", `String name)
    ; ("kind", `Int kind)
    ; (* function *)
      ( "location"
      , `Assoc
          [ ("uri", `String file)
          ; ("range", LSP.mk_range Fleche.Types.(to_range pos))
          ] )
    ]

let _kind_of_type _tm = 13
(* let open Terms in let open Timed in let is_undef = option_empty !(tm.sym_def)
   && List.length !(tm.sym_rules) = 0 in match !(tm.sym_type) with | Vari _ ->
   13 (* Variable *) | Type | Kind | Symb _ | _ when is_undef -> 14 (* Constant
   *) | _ -> 12 (* Function *) *)

let do_symbols ofmt ~id params =
  let file, doc = grab_doc params in
  let f loc id = mk_syminfo file (Names.Id.to_string id, "", 12, loc) in
  let ast = List.map (fun v -> v.Fleche.Doc.ast) doc.Fleche.Doc.nodes in
  let slist = Coq.Ast.grab_definitions f ast in
  let msg = LSP.mk_reply ~id ~result:(`List slist) in
  LIO.send_json ofmt msg

let get_docTextPosition params =
  let document = dict_field "textDocument" params in
  let file = string_field "uri" document in
  let pos = dict_field "position" params in
  let line, character = (int_field "line" pos, int_field "character" pos) in
  (file, (line, character))

(* XXX refactor *)
let do_hover ofmt ~id params =
  let uri, point = get_docTextPosition params in
  let doc = Hashtbl.find doc_table uri in
  let info_string =
    Fleche.Info.LC.info ~doc ~point Exact |> Option.default "no info"
  in
  let result =
    `Assoc
      [ ( "contents"
        , `Assoc
            [ ("kind", `String "markdown"); ("value", `String info_string) ] )
      ]
  in
  let msg = LSP.mk_reply ~id ~result in
  LIO.send_json ofmt msg

let do_completion ofmt ~id params =
  let uri, _ = get_docTextPosition params in
  let doc = Hashtbl.find doc_table uri in
  let f _loc id = `Assoc [ ("label", `String Names.Id.(to_string id)) ] in
  let ast = List.map (fun v -> v.Fleche.Doc.ast) doc.Fleche.Doc.nodes in
  let clist = Coq.Ast.grab_definitions f ast in
  let result = `List clist in
  let msg = LSP.mk_reply ~id ~result in
  LIO.send_json ofmt msg
(* LIO.log_error "do_completion" (string_of_int line ^"-"^ string_of_int pos) *)

(* Replace by ppx when we can print goals properly in the client *)
let mk_hyp { Coq.Goals.names; def = _; ty } : Yojson.Safe.t =
  let names = List.map (fun id -> `String (Names.Id.to_string id)) names in
  let ty = Pp.string_of_ppcmds ty in
  `Assoc [ ("names", `List names); ("ty", `String ty) ]

let mk_goal { Coq.Goals.info = _; ty; hyps } : Yojson.Safe.t =
  let ty = Pp.string_of_ppcmds ty in
  `Assoc [ ("ty", `String ty); ("hyps", `List (List.map mk_hyp hyps)) ]

let mk_goals { Coq.Goals.goals; _ } = List.map mk_goal goals
let mk_goals = Option.cata mk_goals []

let goals_mode =
  if !Fleche.Config.v.goal_after_tactic then Fleche.Info.PrevIfEmpty
  else Fleche.Info.Prev

let do_goals ofmt ~id params =
  let uri, point = get_docTextPosition params in
  let doc = Hashtbl.find doc_table uri in
  let goals = Fleche.Info.LC.goals ~doc ~point goals_mode in
  let result = `List (mk_goals goals) in
  let msg = LSP.mk_reply ~id ~result in
  LIO.send_json ofmt msg

let memo_cache_file = ".coq-lsp.cache"

let memo_save_to_disk () =
  try
    Fleche.Memo.save_to_disk ~file:memo_cache_file;
    Log.log_error "memo" "cache saved to disk"
  with exn ->
    Log.log_error "memo" (Printexc.to_string exn);
    Sys.remove memo_cache_file;
    ()

(* We disable it for now, see todo.org for more information *)
let memo_save_to_disk () = if false then memo_save_to_disk ()

let memo_read_from_disk () =
  try
    if Sys.file_exists memo_cache_file then (
      Log.log_error "memo" "trying to load cache file";
      Fleche.Memo.load_from_disk ~file:memo_cache_file;
      Log.log_error "memo" "cache file loaded")
    else Log.log_error "memo" "cache file not present"
  with exn ->
    Log.log_error "memo" ("loading cache failed: " ^ Printexc.to_string exn);
    Sys.remove memo_cache_file;
    ()

let memo_read_from_disk () = if false then memo_read_from_disk ()

(* The rule is: we keep the latest change check notification in the variable; it
   is only served when the rest of requests are served.

   Note that we should add a method to detect stale requests; maybe cancel them
   when a new edit comes. *)
let change_pending = ref None
let request_queue = Queue.create ()

let process_input (com : J.t) =
  let dict = U.to_assoc com in
  let method_ = string_field "method" dict in
  match method_ with
  | "textDocument/didChange" ->
    (* TODO: cancel all requests? *)
    change_pending := Some dict;
    Control.interrupt := true
  | _ ->
    Queue.push dict request_queue;
    Control.interrupt := true

exception Lsp_exit

(* XXX: We could split requests and notifications but with the OCaml theading
   model there is not a lot of difference yet; something to think for the
   future. *)
let dispatch_message ofmt ~state dict =
  let id = oint_field "id" dict in
  (* LIO.log_error "lsp" ("recv request id: " ^ string_of_int id); *)
  let params = odict_field "params" dict in
  match string_field "method" dict with
  (* Requests *)
  | "initialize" -> do_initialize ofmt ~id params
  | "shutdown" -> do_shutdown ofmt ~id
  (* Symbols in the document *)
  | "textDocument/completion" -> do_completion ofmt ~id params
  | "textDocument/documentSymbol" -> do_symbols ofmt ~id params
  | "textDocument/hover" -> do_hover ofmt ~id params
  (* Proof-specific stuff *)
  | "proof/goals" -> do_goals ofmt ~id params
  (* Notifications *)
  | "textDocument/didOpen" -> do_open ofmt ~state params
  | "textDocument/didChange" -> do_change ofmt ~state params
  | "textDocument/didClose" -> do_close ofmt params
  | "textDocument/didSave" -> memo_save_to_disk ()
  | "exit" -> raise Lsp_exit
  (* NOOPs *)
  | "initialized" | "workspace/didChangeWatchedFiles" -> ()
  | msg -> Log.log_error "no_handler" msg

let dispatch_message ofmt ~state com =
  try dispatch_message ofmt ~state com with
  | U.Type_error (msg, obj) -> Log.log_object msg obj
  | Lsp_exit -> raise Lsp_exit
  | exn ->
    let bt = Printexc.get_backtrace () in
    let iexn = Exninfo.capture exn in
    Log.log_error "process_queue"
      (if Printexc.backtrace_status () then "bt=true" else "bt=false");
    let method_name = string_field "method" com in
    Log.log_error "process_queue" ("exn in method: " ^ method_name);
    Log.log_error "process_queue" (Printexc.to_string exn);
    Log.log_error "process_queue" Pp.(string_of_ppcmds CErrors.(iprint iexn));
    Log.log_error "BT" bt

let rec process_queue ofmt ~state =
  (match Queue.peek_opt request_queue with
  | None -> (
    (* Log.log_error "process_queue" "queue is empty, yielding!"; *)
    match !change_pending with
    | Some com ->
      Control.interrupt := false;
      dispatch_message ofmt ~state com;
      (* Only if completed! *)
      if check_completed com then change_pending := None
    | None -> Thread.delay 0.1)
  | Some com ->
    (* We let Coq work normally now *)
    Control.interrupt := false;
    (* TODO we should optimize the queue *)
    ignore (Queue.pop request_queue);
    Log.log_error "process_queue" "We got job to do";
    dispatch_message ofmt ~state com);
  process_queue ofmt ~state

let lsp_cb oc =
  Fleche.Io.CallBack.
    { log_error = Log.log_error
    ; send_diagnostics =
        (fun ~uri ~version diags ->
          lsp_of_diags ~uri ~version diags |> Lsp.Io.send_json oc)
    }

let lvl_to_severity (lvl : Feedback.level) =
  match lvl with
  | Feedback.Debug -> 5
  | Feedback.Info -> 4
  | Feedback.Notice -> 3
  | Feedback.Warning -> 2
  | Feedback.Error -> 1

let mk_fb_handler () =
  let q = ref [] in
  ( (fun Feedback.{ contents; _ } ->
      match contents with
      | Message (lvl, loc, msg) ->
        let lvl = lvl_to_severity lvl in
        q := (loc, lvl, msg) :: !q
      | _ -> ())
  , q )

let lsp_main log_file std vo_load_path ml_include_path =
  LSP.std_protocol := std;
  Exninfo.record_backtrace true;

  let oc = F.std_formatter in

  (* Setup logging *)
  let client_cb message = LIO.logMessage oc ~lvl:2 ~message in
  Log.start_log ~client_cb log_file;

  let fb_handler, fb_queue = mk_fb_handler () in

  Fleche.Io.CallBack.set (lsp_cb oc);

  let load_module = Dynlink.loadfile in
  let load_plugin = Coq.Loader.plugin_handler None in

  let debug = Fleche.Debug.backtraces in
  let state =
    ( Coq.Init.(coq_init { fb_handler; debug; load_module; load_plugin })
    , vo_load_path
    , ml_include_path
    , fb_queue )
  in

  memo_read_from_disk ();

  let (_ : Thread.t) = Thread.create (fun () -> process_queue oc ~state) () in

  let rec loop () =
    (* XXX: Implement a queue, compact *)
    let com = LIO.read_request stdin in
    if Fleche.Debug.read then Log.log_object "read" com;
    process_input com;
    loop ()
  in
  try loop () with
  | (LIO.ReadError "EOF" | Lsp_exit) as exn ->
    let reason =
      "exiting" ^ if exn = Lsp_exit then "" else " [uncontrolled LSP shutdown]"
    in
    Log.log_error "main" reason;
    LIO.logMessage oc ~lvl:1 ~message:("server " ^ reason);
    Log.end_log ();
    flush_all ()
  | exn ->
    let bt = Printexc.get_backtrace () in
    let exn, info = Exninfo.capture exn in
    let exn_msg = Printexc.to_string exn in
    Log.log_error "fatal error" (exn_msg ^ bt);
    Log.log_error "fatal_error [coq iprint]"
      Pp.(string_of_ppcmds CErrors.(iprint (exn, info)));
    LIO.logMessage oc ~lvl:1 ~message:("server crash: " ^ exn_msg ^ bt);
    Log.end_log ();
    flush_all ()

(* Arguments handling *)
open Cmdliner

(* let bt =
 *   let doc = "Enable backtraces" in
 *   Arg.(value & flag & info ["bt"] ~doc) *)

let log_file =
  let doc = "Log to $(docv)" in
  Arg.(value & opt string "log-lsp.txt" & info [ "log_file" ] ~docv:"FILE" ~doc)

let std =
  let doc = "Restrict to standard LSP protocol" in
  Arg.(value & flag & info [ "std" ] ~doc)

let coq_lp_conv ~implicit (unix_path, lp) =
  { Loadpath.coq_path = Libnames.dirpath_of_string lp
  ; unix_path
  ; has_ml = true
  ; implicit
  ; recursive = true
  }

let coqlib =
  let doc =
    "Load Coq.Init.Prelude from $(docv); plugins/ and theories/ should live \
     there."
  in
  Arg.(
    value
    & opt string Coq_config.coqlib
    & info [ "coqlib" ] ~docv:"COQPATH" ~doc)

let rload_path : Loadpath.vo_path list Term.t =
  let doc =
    "Bind a logical loadpath LP to a directory DIR and implicitly open its \
     namespace."
  in
  Term.(
    const List.(map (coq_lp_conv ~implicit:true))
    $ Arg.(
        value
        & opt_all (pair dir string) []
        & info [ "R"; "rec-load-path" ] ~docv:"DIR,LP" ~doc))

let load_path : Loadpath.vo_path list Term.t =
  let doc = "Bind a logical loadpath LP to a directory DIR" in
  Term.(
    const List.(map (coq_lp_conv ~implicit:false))
    $ Arg.(
        value
        & opt_all (pair dir string) []
        & info [ "Q"; "load-path" ] ~docv:"DIR,LP" ~doc))

let ml_include_path : string list Term.t =
  let doc = "Include DIR in default loadpath, for locating ML files" in
  Arg.(
    value & opt_all dir [] & info [ "I"; "ml-include-path" ] ~docv:"DIR" ~doc)

let coq_loadpath_default ~implicit coq_path =
  let mk_path prefix = coq_path ^ "/" ^ prefix in
  let mk_lp ~ml ~root ~dir ~implicit =
    { Loadpath.unix_path = mk_path dir
    ; coq_path = root
    ; has_ml = ml
    ; implicit
    ; recursive = true
    }
  in
  let coq_root = Names.DirPath.make [ Libnames.coq_root ] in
  let default_root = Libnames.default_root_prefix in
  [ mk_lp ~ml:true ~root:coq_root ~implicit ~dir:"../coq-core/plugins"
  ; mk_lp ~ml:false ~root:coq_root ~implicit ~dir:"theories"
  ; mk_lp ~ml:true ~root:default_root ~implicit:false ~dir:"user-contrib"
  ]

let term_append l =
  Term.(List.(fold_right (fun t l -> const append $ t $ l) l (const [])))

let lsp_cmd : unit Cmd.t =
  let doc = "Coq LSP Server" in
  let man =
    [ `S "DESCRIPTION"
    ; `P "Experimental Coq LSP server"
    ; `S "USAGE"
    ; `P "See the documentation on the project's webpage for more information"
    ]
  in
  let coq_loadpath =
    Term.(const (coq_loadpath_default ~implicit:true) $ coqlib)
  in
  let vo_load_path = term_append [ coq_loadpath; rload_path; load_path ] in
  Cmd.(
    v
      (Cmd.info "coq-lsp" ~version:"0.01" ~doc ~man)
      Term.(const lsp_main $ log_file $ std $ vo_load_path $ ml_include_path))

let main () =
  let ecode = Cmd.eval lsp_cmd in
  exit ecode

let _ = main ()
