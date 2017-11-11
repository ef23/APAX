(* Sources:
 * https://caml.inria.fr/pub/docs/oreilly-book/html/book-ora187.html
 *)

open Unix

let establish_server server_fun sockaddr =
  let domain = domain_of_sockaddr sockaddr in
  let sock = Unix.socket domain Unix.SOCK_STREAM 0 (* for TCP *)
  in Unix.bind sock sockaddr;
    Unix.listen sock 3;
    while true do
      let (s, caller) = Unix.accept sock in
      match Unix.fork() with
      | 0 ->
        begin
          if Unix.fork() <> 0 then exit 0;
          let inchan = Unix.in_channel_of_descr s (*I think we change this to change where to output*)
          and outchan = Unix.out_channel_of_descr s
          in server_fun inchan outchan;
          close_in inchan;
          close_out outchan;
          exit 0
        end
      | id -> Unix.close s; ignore(Unix.waitpid [] id)
    done

let get_my_addr () =
  (Unix.gethostbyname(Unix.gethostname())).Unix.h_addr_list.(0)

(* [main_server port_num serv_fun] establishes the server at port [port_num]
 * which is capable of the service [serv_fun] *)
let main_server port_num serv_fun =
  try
    let port =  port_num in
    let my_address = get_my_addr() in
    establish_server serv_fun  (Unix.ADDR_INET(my_address, port))
  with
    Failure _ ->
      Printf.eprintf "serv_up : bad port number\n"

(* [uppercase_service ic oc] receives input from input channel [ic] and sends
 * output to output channel [oc]. TODO This is the function we modify to send
 * responses. Currently reads in input from [ic] and sends the uppercase
 * response hence the name. *)
let uppercase_service ic oc =
  try
    while true do
      let s = input_line ic in
      let r = String.uppercase_ascii s
      in output_string oc (r^"\n") ; flush oc
    done
  with
    _ ->
      Printf.printf "End of text\n"; Pervasives.flush Pervasives.stdout; exit 0

(* [go_uppercase_service port_num] starts up a server at port number [port_num]
 *)
let go_uppercase_service port_num =
  Unix.handle_unix_error main_server port_num uppercase_service