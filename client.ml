let main_client client_fun server_addr server_port_num=
   (* if Array.length Sys.argv < 3
   then Printf.printf "usage :  client server port\n"
   else *) let server = server_addr in
        let server_addr =
          try  Unix.inet_addr_of_string server
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


let client_fun ic oc =
   try
     while true do
       print_string  "Request : " ;
       flush Pervasives.stdout ;
       output_string oc ((input_line Pervasives.stdin)^"\n") ;
       (* output_string oc (("KEKEKEKEK")^"\n") ; *)
       flush oc ;
       let r = input_line ic
       in Printf.printf "Response : %s\n\n" r;
          if r = "END" then ( Unix.shutdown_connection ic ; raise Exit) ;
     done
   with
       Exit -> exit 0
     | exn -> Unix.shutdown_connection ic ; raise exn  ;;

let go_client server_addr server_port_num = main_client client_fun server_addr server_port_num ;;