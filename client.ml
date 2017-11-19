(* DO NOT OPEN ASYNC OR CORE BECAUSE THAT WILL OVERWRITE THE STANDARD UNIX LIBRARY *)

let main_client client_fun server_addr server_port_num=
   (* if Array.length Sys.argv < 3
   then Printf.printf "usage :  client server port\n"
   else *) let server = server_addr in
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
  print_endline "hi"; 
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
  Async.upon (Async.after (Core.Time.Span.create ~ms:1000 ())) (fun _ -> (query_server ic oc));
  Async.Scheduler.go ()
   
let _ = main_client client_fun "10.132.10.130" "9000"