let rec send_heartbeat () =
  print_endline ("Kk");
  Async.upon (Async.after (Core.Time.Span.create ~ms:1000 ())) (send_heartbeat)

let j () = (Async.Reader.file_contents  "")

send_heartbeat ()
Async.Scheduler.go ()