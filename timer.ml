open Core
open Async

let rec jej x = print_endline "hi"; upon (after (Time.Span.create ~ms:6000 ())) (jej);;

let run =
  print_endline("kek");
  (* while (true) do *)
  upon (after (Time.Span.create ~ms:6000 ())) (jej);
(*   upon (after (Time.Span.create ~ms:3000 ())) (fun _ -> print_endline "line 3");
 *)  (* print_endline "line 4"; *)
(* done; *)
  ();

Scheduler.go ()