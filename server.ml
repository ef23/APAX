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

type ip_address_str = string

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
    neighboringIPs : (string*string) list; (* ip * port *)
    nextIndexList : int list;
    matchIndexList : int list;
}

(* the lower range of the election timeout, in this case 150-300ms*)
let generate_heartbeat =
    let lower = 150 in
    let range = 150 in
    (Random.int range) + lower

let serv_state =  ref {
    id = -1;
    role = Follower;
    currentTerm = 0;
    votedFor = None;
    log = [];
    lastEntry = None;
    commitIndex = 0;
    lastApplied = 0;
    heartbeat = generate_heartbeat;
    neighboringIPs = [];
    nextIndexList = [];
    matchIndexList = [];
}

let vote_counter = ref 0

let change_heartbeat () =
    serv_state := {!serv_state with heartbeat = generate_heartbeat}

let update_neighbors ips id =
    serv_state := {!serv_state with neighboringIPs = ips; id = id}

let get_my_addr () =
    (Unix.gethostbyname(Unix.gethostname())).Unix.h_addr_list.(0)

let listen_address = get_my_addr ()
let port = 9000
let backlog = 10

let () = Lwt_log.add_rule "*" Lwt_log.Info


let req_append_entries msg ip_address_str = failwith "u suck"
let res_append_entries msg ip_address_str = failwith "u suck"

let req_request_vote ballot ip_address_str =
    let json = {|
      {
        "term": ballot.term,
        "candidate_id": ballot.cand_id,
        "last_log_index": ballot.last_log_ind,
        "last_log_term": ballot.last_log_term
      }
    |} in ()
let res_request_vote msg ip_address_str = failwith "succ my zucc"

(* [handle_vote_req msg] handles receiving a vote request message *)
let handle_vote_req msg =
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
        |} in json
        (* send to server *)
    | None -> failwith "kek"

(* [handle_vote_res msg] handles receiving a vote response message *)
let handle_vote_res msg =
    let currTerm = msg |> member "current_term" |> to_int in
    let voted = msg |> member "vote_granted" |> to_bool in
    if voted then vote_counter := !vote_counter + 1

let handle_message msg =

    let msg = Yojson.Basic.from_string msg in
    let msg_type = msg |> member "type" |> to_string in
    match msg_type with
    | "vote_req" -> handle_vote_req msg
    | "vote_res" -> handle_vote_res msg; "gug"
    | "appd_req" -> if !serv_state.role = Candidate
                    then serv_state := {!serv_state with role = Follower};
                    "gug"
    | "appd_res" -> "gug"
    | _ -> "gug"

let rec send_heartbeat oc () =
    Lwt_io.write_line oc "test"; Lwt_io.flush oc;
    Async.upon (Async.after (Core.Time.Span.create ~ms:1000 ())) (send_heartbeat oc) (*TODO test with not hardcoded values for heartbeat*)


let rec handle_connection ic oc () =
    Lwt_io.read_line_opt ic >>=
    (fun msg ->
        match msg with
        | Some msg ->
            let reply = handle_message msg in
            Lwt_io.write_line oc reply >>= handle_connection ic oc
        | None -> Lwt_log.info "Connection closed" >>= return)

let accept_connection conn =
    print_endline "accepted";
    let fd, _ = conn in
    let ic = Lwt_io.of_fd Lwt_io.Input fd in
    let oc = Lwt_io.of_fd Lwt_io.Output fd in
    Lwt.on_failure (handle_connection ic oc ()) (fun e -> Lwt_log.ign_error (Printexc.to_string e));
    Async.upon (Async.after (Core.Time.Span.create ~ms:1000 ())) (send_heartbeat oc); (*TODO test with not hardcoded values for heartbeat*)
    Async.Scheduler.go ();
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
        (* match read_line () with
        | str -> establish_conn str;
 *)
        establish_conn "";
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
    let req_vote_json = build_req_vote () in
    send_rpcs (req_request_vote req_vote_json) neighbors

(* let dummy_get_oc ip = failwith "replace with what maria and janice implement"
let rec send_all_heartbeats ips =
    match ips with
    | [] -> ()
    | h::t ->
        let oc = dummy_get_oc h in
        (* TODO defer this? *)
        send_heartbeat oc ();
        send_all_heartbeats t *)

(* [init_heartbeats ()] starts a new thread to periodically send heartbeats *)
let rec init_heartbeats () = ()

(* [act_leader ()] executes all leader responsibilities, namely sending RPCs
 * and listening for client requests
 * 
 * if a leader receives a client request, they will process it accordingly *)
and act_leader () =
    (* start thread to periodically send heartbeats *)
    init_heartbeats ()
    (* TODO listen for client req and send appd_entries *)

(* [act_candidate ()] executes all candidate responsibilities, namely sending
 * vote requests and ending an election as a winner/loser/stall
 *
 * if a candidate receives a client request, they will reply with an error *)
and act_candidate () =
    serv_state := {!serv_state with heartbeat = generate_heartbeat};
    start_election;
    (* call act_candidate again if timer runs out *)
    (* now listen for responses to the req_votes *)
    let rec listen () =
        if !vote_counter > ((List.length !serv_state.neighboringIPs) / 2) then
            win_election ()
        (* TODO this is probably not correct *)
        else listen ()
    in listen ()

(* [act_follower ()] executes all follower responsibilities, namely starting
 * elections, responding to RPCs, and redirecting client calls to the leader
 * 
 * if a follower receives a client request, they will send it as a special RPC
 * to the leader, and then receive the special RPC and reply back to the client
 *)
and act_follower () = failwith "TODO"

(* [win_election ()] transitions the server from a candidate to a leader and 
 * executes the appropriate actions *)
and win_election () =
    (* transition to Leader role *)
    serv_state := {!serv_state with role = Leader};
    (* send heartbeats *)
    act_leader ()

and lose_election () =
    (* transition to Follower role *)
    serv_state := {!serv_state with role = Follower};
    act_follower ()

(* [terminate_election ()] executes when timeout occurs in the middle of an
 * election with no resolution (i.e. no one wins or loses) *)
and terminate_election () =
    change_heartbeat ();
    start_election ()

let _ =
    let sock = create_socket () in
    let serve = create_server sock in

    Lwt_main.run @@ serve ()