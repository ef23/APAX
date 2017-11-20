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
    heartbeat: int;
    neighboringIPs : string list
}

let counter = ref 0

(* the lower range of the election timeout, in this case 150-300ms*)
let generate_heartbeat =
    let lower = 150 in
    let range = 150 in
    (Random.int range) + lower

let change_heartbeat st =
    {st with heartbeat = generate_heartbeat}

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
    heartbeat = generate_heartbeat;
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
    print_endline "kek";
    let rec serve () =
        Lwt_unix.accept sock >>= accept_connection >>= serve
    in serve

    (* DO NOT OPEN ASYNC OR CORE BECAUSE THAT WILL OVERWRITE THE STANDARD UNIX LIBRARY *)

let main_client client_fun server_addr server_port_num=
    print_endline "help";
    let server = server_addr in
    let server_addr =
      try Unix.inet_addr_of_string server
      with Failure("inet_addr_of_string") ->
             try  (Unix.gethostbyname server).Unix.h_addr_list.(0)
             with Not_found ->
                    Printf.eprintf "%s : Unknown server\n" server ;
                    exit 2
    in try
         let port = int_of_string (server_port_num) in
         let sockaddr = Unix.ADDR_INET(server_addr,port) in
         let ic,oc = Unix.open_connection sockaddr
         in client_fun ic oc ;
            Unix.shutdown_connection ic
       with Failure("int_of_string") -> Printf.eprintf "bad port number";
                                        exit 2 ;;

let rec jej x = 
  Async.upon (Async.after (Core.Time.Span.create ~ms:1000 ())) (jej)

let rec query_server ic oc = 
  try
    print_string  "Request : ";
    print_string (string_of_float (Unix.time ()));
    flush Pervasives.stdout;
    (* output_string oc ((input_line Pervasives.stdin)^"\n") ; *)
    output_string oc (("read")^"\n"); (*make client automatically do stuff. can reuse in server code*)
    output_string oc (("inc")^"\n");
    flush oc;
    let r = input_line ic
    in Printf.printf "Response : %s\n\n" r;
    flush oc;
    if r = "END" then (Unix.shutdown_connection ic; raise Exit);
    Async.upon (Async.after (Core.Time.Span.create ~ms:1000 ())) (fun _ -> (query_server ic oc));
  with
    | Exit -> exit 0
    | exn -> Unix.shutdown_connection ic ; raise exn

let client_fun ic oc =
  (* this would be a heartbeat thing *)
  Async.upon (Async.after (Core.Time.Span.create ~ms:1000 ())) (jej);
  (* this would be a main func thing *)
  Async.upon (Async.after (Core.Time.Span.create ~ms:1000 ())) (fun _ -> (query_server ic oc))
   
let run_as_client = main_client client_fun "10.132.10.130" "9000"

let _ =
    let sock = create_socket () in
    let serve = create_server sock in
    Async.upon (Async.after (Core.Time.Span.create ~ms:10 ())) (Lwt_main.run @@ serve ());
    Async.upon (Async.after (Core.Time.Span.create ~ms:1000 ())) (fun _ -> run_as_client);
    Async.Scheduler.go ()
