(** Multi-client server example.
*
*     Clients can increment a shared counter or read its current value.
*
*         Build with: ocamlfind ocamlopt -package lwt,lwt.unix -linkpkg -o server ./server.ml
*          *)

open Lwt

(* Shared mutable counter *)
type id = int

type role = | Follower | Candidate | Leader

type state = {
    role : role;
(*  currentTerm : int;
    votedFor : int;
    log : entry list;
    commitIndex : int;
    lastApplied : int;
    nextIndex : int;
    matchIndex : int; *)

    neighboringIPs : string list
}

let counter = ref 0

(* the lower range of the election timeout, in this case 150-300ms*)
let lower = 150
let range = 150 in

let gen_rand_counter =
    (Random.int range) + lower

let init_state ips = {
    role = Leader;
(*     currentTerm : int;
    votedFor : int;
    log : entry list;
    commitIndex : int;
    lastApplied : int;
    nextIndex : int;
    matchIndex : int; *)
    neighboringIPs = ips;
}

let transition st new_role = {st with role = new_role}


let get_my_addr () =
    (Unix.gethostbyname(Unix.gethostname())).Unix.h_addr_list.(0)

let listen_address = get_my_addr ()
let port = 9000
let backlog = 10

let () = Lwt_log.add_rule "*" Lwt_log.Info

let handle_message msg =
    match msg with
    | "read" -> string_of_int !counter
    | "inc"  -> counter := !counter + 1; "Counter has been incremented"
    | _      -> "Unknown command"

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

let () =
    let sock = create_socket () in
    let serve = create_server sock in
    Lwt_main.run @@ serve ()
