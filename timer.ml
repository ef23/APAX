open Core
open Async

let run =
  print_endline("kek");
  (* while (true) do *)
  upon (after (Time.Span.create ~ms:6000 ())) (fun _ -> print_endline "line 2");
(*   upon (after (Time.Span.create ~ms:3000 ())) (fun _ -> print_endline "line 3");
 *)  (* print_endline "line 4"; *)
(* done; *)
  ();;

Scheduler.go ()