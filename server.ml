(** Multi-client server example.
*
*     Clients can increment a shared counter or read its current value.
*
*         Build with: ocamlfind ocamlopt -package lwt,lwt.unix -linkpkg -o server ./server.ml
*          *)

open Lwt
open Log
open Request_vote_rpc
open Append_entries_rpc
open Yojson.Basic.Util

type role = | Follower | Candidate | Leader

type state = {
    id : string;
    leader_id: string;
    role : role;
    currentTerm : int;
    votedFor : string option;
    log : (int * entry) list;
    commitIndex : int;
    lastApplied : int;
    heartbeat : int;
    neighboringIPs : (string*int) list; (* ip * port *)
    nextIndexList : int list;
    matchIndexList : int list;
    internal_timer : int;
}




(* the lower range of the elec tion timeout, in th is case 150-300ms*)
let generate_heartbeat () =
    let lower = 150 in
    let range = 150 in
    (Random.int range) + lower

let get_my_addr () =
    (Unix.gethostbyname(Unix.gethostname())).Unix.h_addr_list.(0)

let serv_state = ref {
    id = "";
    leader_id = "";
    role = Follower;
    currentTerm = 0;
    votedFor = None;
    log = [];
    commitIndex = 0;
    lastApplied = 0;
    heartbeat = 0;
    neighboringIPs = [];
    nextIndexList = [];
    matchIndexList = [];
    internal_timer = 0;
}


(* [last_entry ()] is the last entry added to the server's log
 * The log must be sorted in reverse chronological order *)
let last_entry () =
    match !serv_state.log with
    | [] -> None
    | (_, e)::_ -> Some e

let get_my_addr () =
    (Unix.gethostbyname(Unix.gethostname())).Unix.h_addr_list.(0)

let full_addr_str port_num =
    Unix.string_of_inet_addr (get_my_addr ()) ^ ":" ^ (string_of_int port_num)

let read_neighboring_ips port_num =
  let ip_regex = "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*" in
  let port_regex = "\:[0-9]*" in
  let port_regex = "[0-9]" in
  let rec process_file f_channel =
    try
      let line = Pervasives.input_line f_channel in
      let _ = Str.search_forward (Str.regexp ip_regex) line 0 in
      let ip_str = Str.matched_string line in
      let _ = Str.search_forward (Str.regexp port_regex) line 0 in
      let ip_len = String.length ip_str in
      let port_int = int_of_string (Str.string_after line (ip_len + 1)) in
      let new_ip = (ip_str, port_int) in
      if new_ip <> ( Unix.string_of_inet_addr (get_my_addr ()), port_num) then
        let updated_ips = new_ip::!serv_state.neighboringIPs in
        serv_state := {!serv_state with neighboringIPs = updated_ips};
      else
        ();
      process_file f_channel
    with
    | End_of_file -> Pervasives.close_in f_channel; ()
  in
  process_file (Pervasives.open_in "ips")

let curr_role_thr = ref None

let vote_counter = ref 0
let response_count = ref 0
let success_count = ref 0

let change_heartbeat () =
    let new_heartbeat = generate_heartbeat () in
    serv_state := {!serv_state with
            heartbeat = new_heartbeat;
            internal_timer = new_heartbeat;
        }

let dec_timer () = print_endline "dec timer"; serv_state :=
    {
        !serv_state with internal_timer = (!serv_state.internal_timer - 1);
    }

let update_neighbors ips id =
    serv_state := {!serv_state with neighboringIPs = ips; id = id}


let output_channels = ref []

let listen_address = get_my_addr ()
let port = 9000
let backlog = 10

let () = Lwt_log.add_rule "*" Lwt_log.Info

let send_msg str oc =
    print_endline ("sending: "^str);
    Lwt_io.write_line oc str; Lwt_io.flush oc

(* LOG REPLICATIONS *)

let stringify_entry (e:entry): string =
  let json =
    "{" ^
      "\"value\":" ^ (string_of_int e.value) ^ "," ^
      "\"entryTerm\":" ^ (string_of_int e.entryTerm) ^ "," ^
      "\"index\":" ^ (string_of_int e.index) ^
    "}"
  in json


let req_append_entries (msg : append_entries_req) oc =
    let json =
       "{" ^
        "\"type\": appd_req," ^
        "\"term\":" ^ (string_of_int msg.ap_term) ^"," ^
        "\"leader_id\":" ^ (msg.leader_id) ^ "," ^
        "\"prev_log_index\": " ^ (string_of_int msg.prev_log_index) ^ "," ^
        "\"prev_log_term\": " ^ (string_of_int msg.prev_log_term) ^ "," ^
        "\"entries\":" ^
        (List.fold_left (fun a e -> (stringify_entry e) ^ "\n" ^ a) "" msg.entries) ^ "," ^
        "\"leader_commit\":" ^ (string_of_int msg.leader_commit) ^
      "}"
    in send_msg json oc
(*

    failwith
 "kinda same code as req_request_vote. sending json. entries usu just one. commit index is that of leader's state.
 listen for responses.
 - if responses are term and boolean succcesss (append entries rpc mli) then incr ref count of followers ok
 - then when majority, incr commit index

 " *)

(*[res_append_entries ae_res oc] sends the stringified append entries response
 * [ae_res] to the output channel [oc]*)
let res_append_entries (ae_res:append_entries_res) oc =
    let json =
      "{" ^
        "\"success\":" ^ string_of_bool ae_res.success ^"," ^
        "\"currentTerm\":"  ^ string_of_int ae_res.current_term ^
      "}"
    in send_msg json oc

(* [json_es entries] should return a list of entries parsed from the string [entries].
 * - requires: [entries] has at least one entry in it
 *)
let json_es (entries:string): entry list =
    let entries_str_lst =  Str.split (Str.regexp "[\n]+") entries in
    let extract_record e =
        let json =  Yojson.Basic.from_string e in
        let value = json |> member "value" |> to_int in
        let entry_term = json |> member "entryTerm" |> to_int in
        let ind = json |> member "index" |> to_int in
        {
            value = value;
            entryTerm = entry_term;
            index = ind;
        }
    in
    let ocaml_entries = List.map extract_record entries_str_lst in
    ocaml_entries


(* [mismatch_log l pli plt] returns true if log [l] doesnt contain an entry at
 * index [pli] with entry term [plt]; else false *)
let mismatch_log (my_log:(int*entry) list) prev_log_index prev_log_term =
    (* returns nth entry of the log *)
    if prev_log_index > (List.length my_log + 1) then true
    else
        match (List.find_opt (fun (i,e) -> i = prev_log_index) my_log) with
        | None -> true
        | Some (_,e) -> if e.entryTerm = prev_log_term then false else true

(* [process_conflicts entries] goes through the server's log and removes entries
 * that conflict (same index different term) with those in [entries] *)
let process_conflicts entries =
    (* [does_conflict e1 e2] returns true if e1 has a different term than e2
     * -requires e1 and e2 to have the same index *)
    let does_conflict log_e new_e =
        if log_e.entryTerm = new_e.entryTerm then false else true in

    (* given a new entry e, go through the log and return a new (shorter) log
     * if we find a conflict; otherwise return the original log *)
    let rec iter_log old_l new_l new_e =
        match new_l with
        | [] -> old_l
        | (i,log_e)::t ->
            if (i = new_e.index && does_conflict log_e new_e) then t
            else iter_log old_l t new_e in

    let old_log = !serv_state.log in

    (* [iter_entries el s_log] looks for conflicts for each entry in [el]
     * and keeps track of the shortest log [short_log] *)
    let rec iter_entries el short_log =
        match el with
        | [] -> short_log
        | e::t -> let new_log = iter_log old_log old_log e in
            if (List.length new_log < List.length short_log) then
                iter_entries t new_log
            else iter_entries t short_log in

    let n_log = iter_entries entries old_log in
    serv_state := {!serv_state with log = n_log}; ()

let rec append_new_entries (entries : entry list) : unit =
    let entries = List.rev_append entries [] in
    let rec append_new (entries: entry list):unit =
        match entries with
        | [] -> ()
        | h::t ->
            begin
                if List.exists (fun (_,e) -> e = h) !serv_state.log
                then append_new t
                else
                let old_st_log = !serv_state.log in
                let new_ind = List.length old_st_log + 1 in
                let new_entry = {h with index = new_ind} in
                let new_addition = (new_ind, new_entry) in
                serv_state := {!serv_state with log = new_addition::old_st_log};
                append_new t
            end
    in
    append_new entries

let last_entry_idx () = match !serv_state.log with | (i,_)::t -> i | [] -> 0

let handle_ae_req msg oc =
    let ap_term = msg |> member "ap_term" |> to_int in
    let leader_id = msg |> member "leader_id" |> to_string in
    let prev_log_index = msg |> member "prev_log_index" |> to_int in
    let prev_log_term = msg |> member "prev_log_term" |> to_int in
    let entries = msg |> member "entries" |> to_string |> json_es in
    let leader_commit = msg |> member "leader_commit" |> to_int in
    let success_bool =
        if ap_term < !serv_state.currentTerm then false (* 1 *)
        else if mismatch_log !serv_state.log prev_log_index prev_log_term then false (* 2 *)
        else true
    in
    let ae_res = {
        success = success_bool;
        current_term = !serv_state.currentTerm;
    } in
    process_conflicts entries; (* 3 *)
    append_new_entries entries; (* 4 *)
    if leader_commit > !serv_state.commitIndex
    then serv_state := {!serv_state with commitIndex = min leader_commit (last_entry_idx ())}; (* 5 *)
    res_append_entries ae_res oc

    (* failwith "parse every json field in AE RPC. follow the receiver implementation in the pdf" *)

let handle_ae_res msg oc =
    let current_term = msg |> member "current_term" |> to_int in
    let success = msg |> member "success" |> to_bool in

    (* TODO wtf do we do with current_term??? *)

    let s_count = (if success then !success_count + 1 else !success_count) in
    let t_count = !response_count + 1 in
    if s_count > ((List.length !serv_state.neighboringIPs) / 2) then
        ((* reset counters *)
        response_count := 0; success_count := 0;
        (* TODO commit to log *)
        ())
    else if t_count = List.length !serv_state.neighboringIPs then
        ((* reset reset counters *)
        response_count := 0; success_count := 0;
        ()) (* TODO notify client of failure *)
    else () (* do nothing basically *)


let req_request_vote ballot oc =
    let json =
      "{\"type\": \"vote_req\",\"term\": " ^ (string_of_int ballot.term) ^",\"candidate_id\": \"" ^ ballot.candidate_id ^ "\",\"last_log_index\": " ^ (string_of_int ballot.last_log_index) ^ ",\"last_log_term\": " ^ (string_of_int ballot.last_log_term) ^ "}"
    in send_msg json oc

(* [res_request_vote msg oc] handles receiving a vote request message *)
let res_request_vote msg oc =
    let candidate_id = msg |> member "candidate_id" |> to_string in
    let continue = match !serv_state.votedFor with
                    | None -> true
                    | Some id -> id=candidate_id in
    let otherTerm = msg |> member "term" |> to_int in
    let last_log_term = msg |> member "last_log_term" |> to_int in
    let last_log_index = msg |> member "last_log_index" |> to_int in
    let vote_granted = continue && otherTerm >= !serv_state.currentTerm in
    let json =
          "{\"current_term\": " ^ (string_of_int !serv_state.currentTerm) ^ ",\"vote_granted\": " ^ (string_of_bool vote_granted) ^ "}"
         in send_msg json oc
    (* match !serv_state.lastEntry with
    | Some log ->
        let curr_log_ind = log.index in
        let curr_log_term = log.entryTerm in
        let vote_granted = continue && otherTerm >= !serv_state.currentTerm &&
        last_log_index >= curr_log_ind && last_log_term >= curr_log_term in
        let json =
          "{\"current_term\": " ^ (string_of_int !serv_state.currentTerm) ^ ",\"vote_granted\": " ^ (string_of_bool vote_granted) ^ "}"
         in send_msg json oc
    | None -> failwith "kek" *)

(* [send_rpcs f] recursively sends RPCs to every ip in [ips] using the
 * partially applied function [f], which is assumed to be one of the following:
 * [req_append_entries msg]
 * [req_request_vote msg] *)
let rec send_rpcs f =
    let lst_o = !output_channels in
    let rec send_to_ocs lst =
      match lst with
      | [] -> print_endline "sent all rpcs!"
      | h::t -> f h; send_to_ocs t in
    send_to_ocs lst_o

(* [get_entry_term e_opt] takes in the value of a state's last entry option and
 * returns the last entry's term, or -1 if there was no last entry (aka the log
 * is empty) *)
let get_entry_term e_opt =
    match e_opt with
    | Some e -> e.entryTerm
    | None -> -1

let get_p_log_idx () =
    match last_entry () with
    | None -> 0
    | Some e -> e.index

let get_p_log_term () =
    match last_entry () with
    | None -> 0
    | Some e -> e.entryTerm

let rec send_heartbeat oc () =
    Lwt_io.write_line oc (
        "{" ^
        "\"type\":\"heartbeat\"," ^
        "leader_id:" ^ !serv_state.leader_id ^ "," ^
        "\"term\":" ^ string_of_int !serv_state.currentTerm ^ "," ^
        "\"prev_log_index\": " ^ (get_p_log_idx () |> string_of_int) ^ "," ^
        "\"prev_log_term\": " ^ (get_p_log_term () |> string_of_int) ^ "," ^
        "\"entries\": \"\"," ^
        "\"leader_commit\":" ^ string_of_int !serv_state.commitIndex ^
        "}");
    Lwt_io.flush oc;
(*TODO change heartbeat to an empty RPC*)
    print_endline "hello";
    Async.upon (Async.after (Core.Time.Span.create ~ms:1000 ())) (send_heartbeat oc) (*TODO test with not hardcoded values for heartbeat*)

let send_heartbeats () =
    let lst_o = !output_channels in
    print_endline " fdsafds";
    let rec send_to_ocs lst =
      match lst with
      | h::t ->
        begin
          print_endline "in send heartbeat match";
          let start_timer oc_in =
          Async.upon (Async.after (Core.Time.Span.create ~ms:1000 ())) (send_heartbeat oc_in)
          in
          ignore (Thread.create start_timer h); send_to_ocs t;
        end
      | [] -> () in
    print_endline "number of ocs";
    print_endline (string_of_int (List.length lst_o));
    send_to_ocs lst_o
    (* Async.Scheduler.go () *)

(* [start_election ()] starts the election for this server by incrementing its
 * term and sending RequestVote RPCs to every other server in the clique *)
let rec start_election () =
    print_endline "election started!";
    (* increment term and vote for self *)
    let curr_term = !serv_state.currentTerm in
    serv_state := {
        !serv_state with currentTerm = curr_term + 1;
                         votedFor = (Some !serv_state.id)
                    };
    vote_counter := !vote_counter + 1;
    let neighbors = !serv_state.neighboringIPs in
    (* ballot is a vote_req *)
    let ballot = {
        term = !serv_state.currentTerm;
        candidate_id = !serv_state.id;
        last_log_index = !serv_state.commitIndex;
        last_log_term = get_entry_term (last_entry ())
    } in
    print_endline "sending rpcs...";
    send_rpcs (req_request_vote ballot)

(* [act_leader ()] executes all leader responsibilities, namely sending RPCs
 * and listening for client requests
 *
 * if a leader receives a client request, they will process it accordingly *)
and act_leader () =
    (* start thread to periodically send heartbeats *)
    print_endline "act leader";
    send_heartbeats (); ()
    (* LOG REPLICATIONS *)
    (* TODO listen for client req and send appd_entries *)
and init_leader () =
    (* let old_thr = !curr_role_thr in *)
    (* Thread.kill old_thr; *)
    print_endline "init leader";
    act_leader ();

(* [act_candidate ()] executes all candidate responsibilities, namely sending
 * vote requests and ending an election as a winner/loser/stall
 *
 * if a candidate receives a client request, they will reply with an error *)
and act_candidate () =
    (* if the candidate is still a follower, then start a new election
     * otherwise terminate. *)
    print_endline "act candidate";
    let check_election_complete () =
        (* if false, then election has not completed, so start new election.
         * Otherwise if true, then don't do anything (equiv of cancelling timer)
         *)
         print_endline (string_of_bool (!serv_state.role = Candidate ));
        if !serv_state.role = Candidate then act_candidate () in

    (* this will be continuously run to check if the election has been won by
     * this candidate *)
    let rec check_win_election () =
        (* print_endline (string_of_int (List.length !serv_state.neighboringIPs));
        print_endline (string_of_int !vote_counter); *)
        (* if majority of votes, proceed to win election *)
        if !vote_counter > ((List.length !serv_state.neighboringIPs) / 2)
            then win_election ()
        else
            check_win_election () in

    (* call act_candidate again if timer runs out *)
    change_heartbeat ();
    start_election ();

    (* continuously check if election has completed and
     * listen for responses to the req_votes *)
    Async.upon (Async.after (Core.Time.Span.create ~ms:!serv_state.heartbeat ())) (check_election_complete);
    Async.upon (Async.after (Core.Time.Span.create ~ms:0 ())) (check_win_election)

and init_candidate () =
    (* let old_thr = !curr_role_thr in *)
    (* Thread.kill old_thr; *)
    change_heartbeat ();
    act_candidate (); ()

(* [act_follower ()] executes all follower responsibilities, namely starting
 * elections, responding to RPCs, and redirecting client calls to the leader
 *
 * if a follower receives a client request, they will send it as a special RPC
 * to the leader, and then receive the special RPC and reply back to the client
 *)
and act_follower () =
    print_endline "act follower";
    print_endline (string_of_int !serv_state.internal_timer);
    (* check if the timeout has expired, and that it has voted for no one *)
    if !serv_state.internal_timer=0 && (!serv_state.votedFor = None)
    then (serv_state := {!serv_state with role=Candidate}; init_candidate ())
    (* if condition satisfied, continue being follower, otherwise start elec *)
    else Async.upon (Async.after (Core.Time.Span.create ~ms:1 ()))
        ((dec_timer (); act_follower))

and init_follower () =
    (* let old_thr = !curr_role_thr in *)
    (* Thread.kill old_thr; *)
    print_endline "init follower";
    act_follower ();

(* [win_election ()] transitions the server from a candidate to a leader and
 * executes the appropriate actions *)
and win_election () =
    (* transition to Leader role *)
    serv_state := {!serv_state with role = Leader};
    (* send heartbeats *)
    init_leader (); ()

(* [lose_election ()] transitions the server from a candidate to a follower
 * and executes the appropriate actions *)
and lose_election () =
    (* transition to Follower role *)
    serv_state := {!serv_state with role = Follower};
    act_follower ()

(* [terminate_election ()] executes when timeout occurs in the middle of an
 * election with no resolution (i.e. no one wins or loses) *)
and terminate_election () =
    change_heartbeat ();
    start_election ()

(* [handle_vote_res msg] handles receiving a vote response message *)
let handle_vote_res msg hi =
    let currTerm = msg |> member "current_term" |> to_int in
    let voted = msg |> member "vote_granted" |> to_bool in
    if voted then vote_counter := !vote_counter + 1

(*[process_heartbeat msg] handles receiving heartbeats from the leader *)
let process_heartbeat msg =
    let l_id = msg |> member "leader_id" |> to_string in
    serv_state := {!serv_state with leader_id = l_id; internal_timer = !serv_state.heartbeat}


let handle_client_as_leader msg =
    failwith "
    1. parse the value field, leader append to own log -- see mli
     (leader's current term & list.length for index)
    2. call req append entries"


let handle_message msg oc =
    print_endline "i am in handle message";
    serv_state := {!serv_state with internal_timer = !serv_state.heartbeat};
    let msg = Yojson.Basic.from_string msg in
    let msg_type = msg |> member "type" |> to_string in
    match msg_type with
    | "heartbeat" -> print_endline "this is a heart"; process_heartbeat msg; ()
    | "sendall" -> send_heartbeats (); ()
    | "vote_req" -> begin print_endline "this is vote req"; res_request_vote msg oc; () end
    | "vote_res" -> handle_vote_res msg oc; ()
    | "appd_req" -> begin print_endline "received app"; if !serv_state.role = Candidate
                    then serv_state := {!serv_state with role = Follower};
                    handle_ae_req msg oc; () end
    | "appd_res" -> ()
    | "client" ->
        (* TODO redirect client to Leader *)
        if !serv_state.role <> Leader then
            (print_endline !serv_state.leader_id; ())
        else
            (* create the append_entries_rpc *)
            (* using 0 to indicate no previous entry *)
            let p_log_idx = get_p_log_idx in
            let p_log_term = get_p_log_term in
            let new_entry = {
                    value = msg |> member "value" |> to_int;
                    entryTerm = msg |> member "entryTerm" |> to_int;
                    index = msg |> member "index" |> to_int;
                } in

            let rpc = {
                ap_term = !serv_state.currentTerm;
                leader_id = !serv_state.id;
                prev_log_index = p_log_idx ();
                prev_log_term = p_log_term ();
                entries = [];
                leader_commit = !serv_state.commitIndex;
            } in

            let old_log = !serv_state.log in
            let new_idx = (List.length old_log) + 1 in
            serv_state := {!serv_state with log = ((new_idx,new_entry)::old_log)};
            req_append_entries rpc oc; ()
    | _ -> ()


(* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
 *                                                                           *
 *                                                                           *
 * EVERYTHING AFTER THIS POINT IS NETWORKING/SERVER STUFF WHICH IS GENERALLY *
 * SEPARATE FROM RAFT IMPLEMENTATION DETAILS                                 *
 *                                                                           *
 *                                                                           *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *)


(* [init_server ()] starts up this server as a follower and anticipates an
 * election. That is, this should ONLY be called as soon as the server begins
 * running (and after it has set up connections with all other servers) *)
let init_server () =
    change_heartbeat ();
    init_follower ();
    Async.Scheduler.go (); ()

let rec handle_connection ic oc () =
    Lwt_io.read_line_opt ic >>=
    (fun msg ->
        match msg with
        | Some m ->
            handle_message m oc;
            (handle_connection ic oc) ();
        | None -> Lwt_log.info "Connection closed" >>= return)

let accept_connection conn =
    print_endline "accepted";
    let fd, _ = conn in
    let ic = Lwt_io.of_fd Lwt_io.Input fd in
    let oc = Lwt_io.of_fd Lwt_io.Output fd in
    Lwt.on_failure (handle_connection ic oc ()) (fun e -> Lwt_log.ign_error (Printexc.to_string e));
    let otherl = !output_channels in
    output_channels := (oc::otherl);
    let iplistlen = List.length (!serv_state.neighboringIPs) in
    if (List.length !output_channels)=iplistlen then init_server ();
    Lwt_log.info "New connection" >>= return

(* this will be filled in the beginning *)

let rec query_server ic oc =
  try
    print_string  "Request : ";
    print_string (string_of_float (Unix.time ()));
    flush Pervasives.stdout;
    (* output_string oc ((input_line Pervasives.stdin)^"\n") ; *)
    output_string oc (("{\"type\":\"appd_res\"}")^"\n"); (*make client automatically do stuff. can reuse in server code*)
    flush oc;
    let r = input_line ic
    in Printf.printf "Response : %s\n\n" r;
    flush oc;
    if r = "END" then (Unix.shutdown_connection ic; raise Exit);
    (*Async.upon (Async.after (Core.Time.Span.create ~ms:1000 ())) (fun _ -> (query_server ic oc));*)
  with
    | Exit -> exit 0
    | exn -> Unix.shutdown_connection ic ; raise exn

let create_socket portnum () =
    let open Lwt_unix in
    let sock = socket PF_INET SOCK_STREAM 0 in
    bind sock @@ ADDR_INET(listen_address, portnum);
    listen sock backlog;
    sock

let main_client address portnum =
    try
        let sockaddr = Lwt_unix.ADDR_INET(Unix.inet_addr_of_string address, portnum) in
        print_endline "main client";
        let%lwt ic, oc = Lwt_io.open_connection sockaddr in
        let otherl = !output_channels in
             output_channels := (oc::otherl);
             let iplistlen = List.length (!serv_state.neighboringIPs) in
             if (List.length !output_channels)=iplistlen then init_server ();
        Lwt_log.info "added connection" >>= return
    with
        Failure("int_of_string") -> Printf.printf "bad port number";
                                        exit 2 ;;

let establish_connections_to_others () =
    print_endline "establish";
    let ip_ports_list = !serv_state.neighboringIPs in
    let rec get_connections lst =
        match lst with
        | [] -> ()
        | (ip_addr, portnum)::t ->
        begin
            print_endline "in begin";
            main_client ip_addr portnum;
            get_connections t;
        end
    in get_connections ip_ports_list

let create_server sock =
    let rec serve () =
        Lwt_unix.accept sock >>= accept_connection >>= serve
    in serve

let doboth () =
    read_neighboring_ips 9003 |> establish_connections_to_others |>
    send_heartbeats ;;

let startserver port_num =
    print_endline "ajsdfjasjdfjasjf";
    read_neighboring_ips port_num;
    let sock = create_socket port_num () in
    let serve = create_server sock in

    Lwt_main.run @@ serve ();;

let startserverest port_num =
    print_endline "ajsdfjasjdfjasjf";
    read_neighboring_ips port_num;
    establish_connections_to_others ();
    let sock = create_socket port_num () in
    let serve = create_server sock in

    Lwt_main.run @@ serve ();;


let rec st port_num =
    Random.self_init ();
    serv_state := {!serv_state with id=((Unix.string_of_inet_addr (get_my_addr ())) ^ ":" ^ (string_of_int port_num))};
    read_neighboring_ips port_num;
    establish_connections_to_others ();
    let sock = create_socket port_num () in
    let serve = create_server sock in
    Lwt_main.run @@ serve ();
    (* any more scheduled tasks will run after this *)

