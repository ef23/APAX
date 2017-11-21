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
    neighboringIPs : string list;
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
let req_request_vote msg ip_address_str = failwith "u suck"
let res_request_vote msg ip_address_str = failwith "succ my zucc"


let handle_message msg =
    let msg_type = (* fill out this with extracting Yojson for call type *) "kek" in
    match msg_type with
    | "vote_req" -> string_of_int !vote_counter
    | "vote_res"  -> vote_counter := !vote_counter + 1; "Counter has been incremented"
    | "appd_req" ->
    | "appd_res" ->
    | _      -> "Unknown command"

let rec send_heartbeat oc () =
    print_endline "jejejejj";
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
    let sock = create_socket () in
    let serve = create_server sock in
    Lwt_main.run @@ serve ();


