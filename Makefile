
compile:
	ocamlbuild -use-ocamlfind -package lwt -package yojson -package lwt.ppx -package async -package core -package websocket -package websocket-lwt.cohttp -tag thread append_entries_rpc.cmo log.cmo request_vote_rpc.cmo server.cmo

clean:
	ocamlbuild -clean