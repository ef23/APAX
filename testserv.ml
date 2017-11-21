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

type ip_address_str = string

let get_my_addr () =
    (Unix.gethostbyname(Unix.gethostname())).Unix.h_addr_list.(0)

let listen_address = get_my_addr ()
let port = 9000
let backlog = 10

let () = Lwt_log.add_rule "*" Lwt_log.Info

let vote_counter = ref 0

let handle_message msg =
    let msg_type = (* fill out this with extracting Yojson for call type *) "vote_req" in
    match msg_type with
    | "vote_req" -> string_of_int !vote_counter
    | "vote_res" -> vote_counter := !vote_counter + 1; "Counter has been incremented"
    | "appd_req" -> "Unknown command"
    | "appd_res" -> "Unknown command"
    | _ -> "Unknown command"

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
        Lwt_unix.accept sock >>= accept_connection >>= serve

    in serve

let _ =
    let sock = create_socket () in
    let serve = create_server sock in

    Lwt_main.run @@ serve ()

