
compile:
	ocamlbuild -use-ocamlfind -package lwt  -package lwt.ppx -package async -package core -tag thread append_entries_rpc.cmo log.cmo request_vote_rpc.cmo server.cmo

clean:
	ocamlbuild -clean