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
    id : int;
    role : role;
    currentTerm : int;
    votedFor : int option;
    log : entry list;
    lastEntry : entry option;
    commitIndex : int;
    lastApplied : int;
    heartbeat : int;
    neighboringIPs : (string*int) list; (* ip * port *)
    nextIndexList : int list;
    matchIndexList : int list;
    internal_timer : int;
}

(* the lower range of the election timeout, in this case 150-300ms*)
let generate_heartbeat =
    let lower = 150 in
    let range = 150 in
    (Random.int range) + lower

let serv_state = ref {
    id = -1;
    role = Follower;
    currentTerm = 0;
    votedFor = None;
    log = [];
    lastEntry = None;
    commitIndex = 0;
    lastApplied = 0;
    heartbeat = 0;
    neighboringIPs = [];
    nextIndexList = [];
    matchIndexList = [];
    internal_timer = 0;
}


let read_neighoring_ips () =
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
      let updated_ips = new_ip::!serv_state.neighboringIPs in
      serv_state := {!serv_state with neighboringIPs = updated_ips};
      process_file f_channel
    with
    | End_of_file -> Pervasives.close_in f_channel; ()
  in
  process_file (Pervasives.open_in "ips")


let vote_counter = ref 0

let change_heartbeat () =
    let new_heartbeat = generate_heartbeat in
    serv_state := {!serv_state with
            heartbeat = new_heartbeat;
            internal_timer = new_heartbeat;
        }

let dec_timer () = serv_state :=
    {
        !serv_state with internal_timer = (!serv_state.internal_timer - 1);
    }

let update_neighbors ips id =
    serv_state := {!serv_state with neighboringIPs = ips; id = id}

let get_my_addr () =
    (Unix.gethostbyname(Unix.gethostname())).Unix.h_addr_list.(0)

let output_channels = ref []

let listen_address = get_my_addr ()
let port = 9000
let backlog = 10

let () = Lwt_log.add_rule "*" Lwt_log.Info

(* LOG REPLICATIONS *)
let req_append_entries msg oc = failwith "u suck"
let res_append_entries msg oc = failwith "u suck"

let req_request_vote ballot oc =
    let json = {|
      {
        "term": ballot.term,
        "candidate_id": ballot.cand_id,
        "last_log_index": ballot.last_log_ind,
        "last_log_term": ballot.last_log_term
      }
    |} in ()

let res_request_vote msg oc = failwith "succ my zucc"

(* [handle_vote_req msg] handles receiving a vote request message *)
let handle_vote_req msg oc =
    let candidate_id = msg |> member "candidate_id" |> to_int in
    let continue = match !serv_state.votedFor with
                    | None -> true
                    | Some id -> id=candidate_id in
    let otherTerm = msg |> member "term" |> to_int in
    let last_log_term = msg |> member "last_log_term" |> to_int in
    let last_log_index = msg |> member "last_log_index" |> to_int in
    match !serv_state.lastEntry with
    | Some log ->
        let curr_log_ind = log.index in
        let curr_log_term = log.entryTerm in
        let vote_granted = continue && otherTerm >= !serv_state.currentTerm &&
        last_log_index >= curr_log_ind && last_log_term >= curr_log_term in
        let json = {|
          {
            "current_term":!serv_state.currentTerm,
            "vote_granted":vote_granted,
          }
        |} in Lwt_io.write_line oc json; Lwt_io.flush oc;
    | None -> failwith "kek"

let set_term i =
    {!serv_state with currentTerm = i}

(* [send_rpcs f ips] recursively sends RPCs to every ip in [ips] using the
 * partially applied function [f], which is assumed to be one of the following:
 * [req_append_entries msg]
 * [req_request_vote msg] *)
let rec send_rpcs f ips =
    match ips with
    | [] -> ()
    | ip::t ->
        let _ = f ip in
        send_rpcs f t

(* [get_entry_term e_opt] takes in the value of a state's last entry option and
 * returns the last entry's term, or -1 if there was no last entry (aka the log
 * is empty) *)
let get_entry_term e_opt =
    match e_opt with
    | Some e -> e.entryTerm
    | None -> -1

let rec send_heartbeat oc () =
    Lwt_io.write_line oc "test"; Lwt_io.flush oc;
    Async.upon (Async.after (Core.Time.Span.create ~ms:1000 ())) (send_heartbeat oc) (*TODO test with not hardcoded values for heartbeat*)

let send_heartbeats () =
    let lst_o = !output_channels in
    let rec send_to_ocs lst =
      match lst with
      | h::t ->
        begin
          let start_timer oc_in =
          Async.upon (Async.after (Core.Time.Span.create ~ms:1000 ())) (send_heartbeat oc_in)
          in
          ignore (Thread.create start_timer h); send_to_ocs t;
        end
      | [] -> () in
    send_to_ocs lst_o; Async.Scheduler.go ()

(* [start_election ()] starts the election for this server by incrementing its
 * term and sending RequestVote RPCs to every other server in the clique *)
let rec start_election () =
    (* increment term *)
    let curr_term = !serv_state.currentTerm in
    serv_state := set_term (curr_term + 1);

    let neighbors = !serv_state.neighboringIPs in
    (* ballot is a vote_req *)
    let ballot = {
        term = !serv_state.currentTerm;
        candidate_id = !serv_state.id;
        last_log_index = !serv_state.commitIndex;
        last_log_term = get_entry_term (!serv_state.lastEntry)
    } in
    send_rpcs (req_request_vote ballot) neighbors

(* [act_leader ()] executes all leader responsibilities, namely sending RPCs
 * and listening for client requests
 *
 * if a leader receives a client request, they will process it accordingly *)
and act_leader () =
    (* start thread to periodically send heartbeats *)
    send_heartbeats ()
    (* LOG REPLICATIONS *)
    (* TODO listen for client req and send appd_entries *)

(* [act_candidate ()] executes all candidate responsibilities, namely sending
 * vote requests and ending an election as a winner/loser/stall
 *
 * if a candidate receives a client request, they will reply with an error *)
and act_candidate () =
    (* if the candidate is still a follower, then start a new election
     * otherwise terminate. *)
    let check_election_complete () =
        if !serv_state.role = Candidate then act_candidate () in

    let rec check_win_election () =
        if !vote_counter > ((List.length !serv_state.neighboringIPs) / 2)
            then win_election ()
        else
            check_win_election () in

    (* call act_candidate again if timer runs out *)
    change_heartbeat ();
    Async.upon (Async.after (Core.Time.Span.create ~ms:1000 ())) (check_election_complete);
    start_election ();

    (* now listen for responses to the req_votes *)
    Async.upon (Async.after (Core.Time.Span.create ~ms:0 ())) (check_win_election);
    ()

and init_candidate () =
    let start_listening act_new_role =
    (Async.upon (Async.after (Core.Time.Span.create ~ms:0 ())) (act_new_role);
    Async.Scheduler.go ()) in
    Thread.create start_listening act_candidate; ()


(* [act_follower ()] executes all follower responsibilities, namely starting
 * elections, responding to RPCs, and redirecting client calls to the leader
 *
 * if a follower receives a client request, they will send it as a special RPC
 * to the leader, and then receive the special RPC and reply back to the client
 *)
and act_follower () =
    if !serv_state.internal_timer=0 && !serv_state.votedFor<>None
    then (serv_state := {!serv_state with role=Candidate}; init_candidate ())
    else Async.upon (Async.after (Core.Time.Span.create ~ms:1 ()))
        ((dec_timer (); act_follower))

and init_follower () =
    let start_listening act_new_role =
    (Async.upon (Async.after (Core.Time.Span.create ~ms:0 ())) (act_new_role);
    Async.Scheduler.go ()) in
    Thread.create start_listening act_follower; ()

(* [win_election ()] transitions the server from a candidate to a leader and
 * executes the appropriate actions *)
and win_election () =
    (* transition to Leader role *)
    serv_state := {!serv_state with role = Leader};
    (* send heartbeats *)
    act_leader (); ()

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

let handle_message msg oc =
    serv_state := {!serv_state with internal_timer = !serv_state.heartbeat};
    let msg = Yojson.Basic.from_string msg in
    let msg_type = msg |> member "type" |> to_string in
    match msg_type with
    | "sendall" -> send_heartbeats (); ()
    | "vote_req" -> handle_vote_req msg oc; ()
    | "vote_res" -> handle_vote_res msg oc; ()
    | "appd_req" -> if !serv_state.role = Candidate
                    then serv_state := {!serv_state with role = Follower}; ()
    | "appd_res" -> ()
    | _ -> ()

let init_server () =
    change_heartbeat ()

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
    Lwt_log.info "New connection" >>= return

let create_socket () =
    let open Lwt_unix in
    let sock = socket PF_INET SOCK_STREAM 0 in
    bind sock @@ ADDR_INET(listen_address, port);
    listen sock backlog;
    sock

let establish_conn server_addr  =
  let server = "10.129.21.219" in
        let server_addr =
          try Unix.inet_addr_of_string server
          with Failure("inet_addr_of_string") ->
                 try  (Unix.gethostbyname server).Unix.h_addr_list.(0)
                 with Not_found ->
                        Printf.eprintf "%s : Unknown server\n" server ;
                        exit 2
        in try
             let port = int_of_string ("9000") in
             let sockaddr = Lwt_unix.ADDR_INET(server_addr,port) in
             let%lwt ic, oc = Lwt_io.open_connection sockaddr
             in handle_connection ic oc ()
        with Failure("int_of_string") -> Printf.eprintf "bad port number";
                                            exit 2 ;;

let create_server sock =
    let rec serve () =
        Lwt_unix.accept sock >>= accept_connection >>= serve
    in serve

let set_term i =
    {!serv_state with currentTerm = i}

(* [send_rpcs f ips] recursively sends RPCs to every ip in [ips] using the
 * partially applied function [f], which is assumed to be one of the following:
 * [req_append_entries msg]
 * [req_request_vote msg] *)
let rec send_rpcs f ips =
    match ips with
    | [] -> ()
    | ip::t ->
        let _ = f ip in
        send_rpcs f t

(* [get_entry_term e_opt] takes in the value of a state's last entry option and
 * returns the last entry's term, or -1 if there was no last entry (aka the log
 * is empty) *)
let get_entry_term e_opt =
    match e_opt with
    | Some e -> e.entryTerm
    | None -> -1

(* [start_election ()] starts the election for this server by incrementing its
 * term and sending RequestVote RPCs to every other server in the clique *)
let start_election () =
    (* increment term *)
    let curr_term = !serv_state.currentTerm in
    serv_state := set_term (curr_term + 1);

    let neighbors = !serv_state.neighboringIPs in
    (* ballot is a vote_req *)
    let ballot = {
        term = !serv_state.currentTerm;
        candidate_id = !serv_state.id;
        last_log_index = !serv_state.commitIndex;
        last_log_term = get_entry_term (!serv_state.lastEntry)
    } in
    send_rpcs (req_request_vote ballot) neighbors

let _ =
    read_neighoring_ips ();
    let sock = create_socket () in
    let serve = create_server sock in

    Lwt_main.run @@ serve ()