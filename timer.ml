open Core
open Async

let rec jej x = print_endline "hi"; upon (after (Time.Span.create ~ms:1000 ())) (jej);;
let rec jej2 x = print_endline "lol"; upon (after (Time.Span.create ~ms:2000 ())) (jej2);;

let _ = upon (after (Time.Span.create ~ms:1000 ())) (jej);;
let _ = upon (after (Time.Span.create ~ms:1100 ())) (jej2);;

Scheduler.go ()