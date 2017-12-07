open Lwt
open Websocket
open Websocket_cohttp_lwt
open Log
open Request_vote_rpc
open Append_entries_rpc
open Yojson.Basic.Util

type role = | Follower | Candidate | Leader

type state = {
    mutable id : string;
    mutable leader_id: string;
    mutable role : role;
    mutable currentTerm : int;
    mutable votedFor : string option;
    mutable log : (int * entry) list; (* index * entry list *)
    mutable commitIndex : int;
    mutable lastApplied : int;
    mutable heartbeat : float;
    mutable neighboringIPs : (string*int) list; (* ip * port *)
    mutable nextIndexList : (string*int) list; (* id * next index *)
    mutable matchIndexList : (string*int) list; (* id * match index *)
    mutable received_heartbeat : bool;
}

let get_ae_response_from = ref []

(* the lower range of the election timeout, in th is case 150-300ms*)
let generate_heartbeat () =
    let lower = 0.150 in
    let range = 0.400 in
    let timer = (Random.float range) +. lower in
    print_endline ("timer:"^(string_of_float timer));
    timer

let get_my_addr () =
    (Unix.gethostbyname(Unix.gethostname())).Unix.h_addr_list.(0)

let serv_state = {
    id = "";
    leader_id = "";
    role = Follower;
    currentTerm = 0;
    votedFor = None;
    log = [];
    commitIndex = 0;
    lastApplied = 0;
    heartbeat = 0.;
    neighboringIPs = [];
    nextIndexList = [];
    matchIndexList = [];
    received_heartbeat = false;
}

(* TODO this needs to be here and not elsewhere kek *)
let get_my_addr () =
    (Unix.gethostbyname(Unix.gethostname())).Unix.h_addr_list.(0)

(* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *

                           NON-STATE SERVER FIELDS

 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *)

let curr_role_thr = ref None

let vote_counter = ref 0
let response_count = ref 0
let success_count = ref 0

let channels = ref []

let listen_address = get_my_addr ()
let port = 9000
let backlog = 10

let () = Lwt_log.add_rule "*" Lwt_log.Info

let hb_interval = (Lwt_unix.sleep 1.)

(* (append_entries_req * int) list that maps the specific request to the number
 * of responses to it with success=true *)
let ae_req_to_count = ref []

(* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *

                         WEBSOCKET CLIENT SERVER FIELDS

 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *)

let res_client_msg = ref "connected!"
let leader_ip = ref ""
let (conn_ws : (Conduit_lwt_unix.flow * Cohttp.Connection.t) option ref) = ref None
let (req_ws : Cohttp_lwt_unix.Request.t option ref) = ref None
let (body_ws : Cohttp_lwt_body.t option ref) = ref None
let num_clients = 1

(* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *

                            HELPER FUNCTIONS

 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *)

(* [id_from_oc cl oc] takes an output channel [oc] and channels+id list [cl] and
 * finds the id corresponding to the channel [oc] *)
let rec id_from_oc cl oc =
    match cl with
    | [] -> None
    | (ip, (_, oc2))::t -> if (oc == oc2) then Some ip else id_from_oc t oc

(* [nindex_from_id id] takes a server id [id] and the nextIndexList and
 * finds the nextIndex of server [id] *)
let rec nindex_from_id id =
    List.assoc id serv_state.nextIndexList

(* [last_entry ()] is the last entry added to the server's log
 * The log must be sorted in reverse chronological order *)
let last_entry () =
    match serv_state.log with
    | [] -> None
    | (_, e)::_ -> Some e

let get_p_log_idx () =
    match last_entry () with
    | None -> 0
    | Some e -> e.index

let get_p_log_term () =
    match last_entry () with
    | None -> 0
    | Some e -> e.entryTerm

let get_my_addr () =
    (Unix.gethostbyname(Unix.gethostname())).Unix.h_addr_list.(0)

let full_addr_str port_num =
    Unix.string_of_inet_addr (get_my_addr ()) ^ ":" ^ (string_of_int port_num)

let change_heartbeat () =
    let new_heartbeat = generate_heartbeat () in
    serv_state.heartbeat <- new_heartbeat

let update_neighbors ips id =
    serv_state.neighboringIPs <- ips;
    serv_state.id <- id

let channels = ref []

(* oc, rpc  *)
let listen_address = get_my_addr ()
let port = 9000
let backlog = 10

let () = Lwt_log.add_rule "*" Lwt_log.Info

let hb_interval = (Lwt_unix.sleep 1.)

let send_msg str oc =
    print_endline ("sending: "^str);
    Lwt_io.write_line oc str; Lwt_io.flush oc

let stringify_e (e:entry): string =
  let json =
    "{" ^
      "\"value\":" ^ (string_of_int e.value) ^ "," ^
      "\"entryTerm\":" ^ (string_of_int e.entryTerm) ^ "," ^
      "\"index\":" ^ (string_of_int e.index) ^
    "}"
  in json

let nindex_from_id ip =
    List.assoc ip serv_state.nextIndexList
(* [oc] is the output channel to send to a server with an ip [ip] *)
let req_append_entries (msg : append_entries_req) (ip : string) oc =
    let json =
       "{" ^
        "\"type\": \"appd_req\"," ^
        "\"term\":" ^ (string_of_int msg.ap_term) ^"," ^
        "\"leader_id\":" ^ (msg.leader_id) ^ "," ^
        "\"prev_log_index\": " ^ (string_of_int msg.prev_log_index) ^ "," ^
        "\"prev_log_term\": " ^ (string_of_int msg.prev_log_term) ^ "," ^
        "\"entries\":" ^
        (List.fold_left (fun a e -> (stringify_e e) ^ "\n" ^ a) "" msg.entries)
        ^ "," ^
        "\"leader_commit\":" ^ (string_of_int msg.leader_commit) ^
      "}"
    in send_msg json oc

(*

    failwith
 "kinda same code as req_request_vote. sending json. entries usu just one. commit index is that of leader's state.
 listen for responses.
 - if responses are term and boolean succcesss (append entries rpc mli) then incr ref count of followers ok
 - then when majority, incr commit index

 " *)

(*[res_append_entries ae_res oc] sends the stringified append entries response
 * [ae_res] to the output channel [oc]*)
let res_append_entries (ae_res:append_entries_res) oc =
    let json =
      "{" ^
        "\"type\":" ^ "\"appd_res\"" ^ "," ^
        "\"success\":" ^ string_of_bool ae_res.success ^"," ^
        "\"currentTerm\":"  ^ string_of_int ae_res.current_term ^
      "}"
    in
    send_msg json oc

(* [json_es entries] should return a list of entries parsed from the string [entries].
 * - requires: [entries] has at least one entry in it
 *)
let json_es (entries:string): entry list =
    let entries_str_lst =  Str.split (Str.regexp "[\n]+") entries in
    let extract_record e =
        let json =  Yojson.Basic.from_string e in
        let value = json |> member "value" |> to_int in
        let entry_term = json |> member "entryTerm" |> to_int in
        let ind = json |> member "index" |> to_int in
        {
            value = value;
            entryTerm = entry_term;
            index = ind;
        }
    in
    let ocaml_entries = List.map extract_record entries_str_lst in
    ocaml_entries

(* [send_rpcs f] recursively sends RPCs to every ip in [ips] using the
 * partially applied function [f], which is assumed to be one of the following:
 * [req_append_entries msg]
 * [req_request_vote msg] *)
let rec send_rpcs f =
    let lst_o = List.map (fun (ip, channel) -> channel) !channels in
    let rec send_to_ocs lst =
      match lst with
      | [] -> print_endline "sent all rpcs!"
      | (ic, oc)::t -> f oc; send_to_ocs t in
    send_to_ocs lst_o

(* [mismatch_log l pli plt] returns true if log [l] doesnt contain an entry at
 * index [pli] with entry term [plt]; else false *)
let mismatch_log (my_log:(int*entry) list) prev_log_index prev_log_term =
    (* returns nth entry of the log *)
    if prev_log_index > (List.length my_log + 1) then true
    else
        match (List.find_opt (fun (i,e) -> i = prev_log_index) my_log) with
        | None -> true
        | Some (_,e) -> if e.entryTerm = prev_log_term then false else true

(* [process_conflicts entries] goes through the server's log and removes entries
 * that conflict (same index different term) with those in [entries] *)
let process_conflicts entries =
    (* [does_conflict e1 e2] returns true if e1 has a different term than e2
     * -requires e1 and e2 to have the same index *)
    let does_conflict log_e new_e =
        if log_e.entryTerm = new_e.entryTerm then false else true in

    (* given a new entry e, go through the log and return a new (shorter) log
     * if we find a conflict; otherwise return the original log *)
    let rec iter_log old_l new_l new_e =
        match new_l with
        | [] -> old_l
        | (i,log_e)::t ->
            if (i = new_e.index && does_conflict log_e new_e) then t
            else iter_log old_l t new_e in

    let old_log = serv_state.log in

    (* [iter_entries el s_log] looks for conflicts for each entry in [el]
     * and keeps track of the shortest log [short_log] *)
    let rec iter_entries el short_log =
        match el with
        | [] -> short_log
        | e::t -> let new_log = iter_log old_log old_log e in
            if (List.length new_log < List.length short_log) then
                iter_entries t new_log
            else iter_entries t short_log in

    let n_log = iter_entries entries old_log in
    serv_state.log <- n_log

(* [append_new_entries entries] adds the new entries to the log
 * the entries must be in reverse chronological order as with the log
 *)
let rec append_new_entries (entries : entry list) : unit =
    let entries = List.rev_append entries [] in
    let rec append_new (entries: entry list):unit =
        match entries with
        | [] -> ()
        | h::t ->
            begin
                if List.exists (fun (_,e) -> e = h) serv_state.log
                then append_new t
                else
                let old_st_log = serv_state.log in
                let new_ind = List.length old_st_log + 1 in
                let new_entry = {h with index = new_ind} in
                let new_addition = (new_ind, new_entry) in
                serv_state.log <- new_addition::old_st_log;
                append_new t
            end
    in
    append_new entries

let rec send_heartbeat oc () =
    print_endline "sending heartbeat";
    let temp_str = "kek" in
    Lwt_io.write_line oc (
        "{" ^
        "\"type\":\"heartbeat\"," ^
        "\"leader_id\":" ^ "\"" ^ serv_state.id ^ "\"" ^ "," ^
        "\"term\":" ^ string_of_int serv_state.currentTerm ^ "," ^
        "\"prev_log_index\": " ^ (get_p_log_idx () |> string_of_int) ^ "," ^
        "\"prev_log_term\": " ^ (get_p_log_term () |> string_of_int) ^ "," ^
        "\"entries\": \"\"," ^
        "\"leader_commit\":" ^ string_of_int serv_state.commitIndex ^
        "}");
    Lwt_io.flush oc;
    Lwt.on_termination (Lwt_unix.sleep serv_state.heartbeat) (fun () -> send_heartbeat oc ())

(* [create_rpc msg] creates an rpc to be sent to the servers based on the [msg]
 * containing the value the client wants to add as well as the leader's term and
 * the index of the entry in the log. Only the leader should call this function
 *)
let create_rpc msg =
    let p_log_idx = get_p_log_idx () in
        let p_log_term = get_p_log_term () in
        let new_entry = {
                value = msg |> member "value" |> to_int;
                entryTerm = msg |> member "entryTerm" |> to_int;
                index = msg |> member "index" |> to_int;
            } in

        let old_log = serv_state.log in
        let new_idx = (List.length old_log) + 1 in
        serv_state.log <- (new_idx,new_entry)::old_log;

        let e = [] in
        let next_index = nindex_from_id serv_state.id in
        let entries_ =
            let rec add_relevant es = function
            | [] -> es
            | (i, e)::t ->
                if i >= next_index
                then add_relevant (e::es) t
                else add_relevant es t
            in
            add_relevant e (List.rev serv_state.log)
        in
        {
            ap_term = serv_state.currentTerm;
            leader_id = serv_state.id;
            prev_log_index = p_log_idx;
            prev_log_term = p_log_term;
            entries = entries_;
            leader_commit = serv_state.commitIndex
        }
(* [force_conform id] forces server with id [id] to conform to the leader's log
 * if there is an inconsistency between the logs (aka the AERes success would be
 * false) *)
let force_conform id =
    let ni = nindex_from_id id in
    (* update the nextIndex for this server to be ni - 1 *)
    let new_indices = List.filter (fun (lst_ip, _) -> lst_ip <> id) serv_state.nextIndexList in
    serv_state.nextIndexList <- (id, ni-1)::new_indices;
    (* TODO do i retry the AEReq here? upon next client req? *)
    ()

(* [update_matchIndex oc] finds the id of the server corresponding to [oc] and
 * updates its matchIndex in this server's matchIndex list
 * -requires the server of [oc] to have responded to an AEReq with true *)
let rec update_match_index oc =
    match (id_from_oc !channels oc) with
    | None -> failwith "uh wtf"
    | Some id ->
        (* basically rebuild the entire matchIndex list lol *)
        let rec apply build mi_list idx =
            match mi_list with
            | [] -> failwith "this should literally never happen lol kill me"
            | (s,i)::t ->
                if s = idx then
                    (* note: nextIndex - matchIndex > 1 if and only if a new
                     * leader comes into power with a significantly larger log
                     * which is a result of unifying a network partition, which
                     * is NOT a feature that we support *)
                    (let n_matchi = List.length serv_state.log in
                    serv_state.matchIndexList <- ([(s,n_matchi)]@t@build); ())
                else apply ((s,i)::build) t idx
        in
        apply [] serv_state.matchIndexList id; ()

(* [update_next_index ] is only used by the leader *)
let update_next_index oc =
    let (ip, (_,_)) = List.find (fun (_, (_, list_oc)) -> oc == list_oc) !channels in
    let new_indices = List.filter (fun (lst_ip, _) -> lst_ip <> ip) serv_state.nextIndexList in
    serv_state.nextIndexList <- (ip, List.length serv_state.log)::new_indices

(* [update_commit_index ()] updates the commitIndex for the Leader by finding an
 * N such that N > commitIndex, a majority of matchIndex values >= N, and the
 * term of the Nth entry in the leader's log is equal to currentTerm *)

let update_commit_index () =
    (* upper bound on N, which is the index of the last entry *)
    let ub = get_p_log_idx () in
    let init_N = serv_state.commitIndex + 1 in

    (* find whether the majority of followers have matchIndex >= N *)
    let rec mi_geq_n count total n li =
        match li with
        | [] -> (count > (total / 2))
        | (_,i)::t ->
            if i >= n then mi_geq_n (count+1) total n t
            else mi_geq_n count total n t in

    (* find the highest such n, n <= ub, such that the above function returns true *)
    let rec find_n ub n high =
        let l = serv_state.matchIndexList in
        if n > ub then high
        else if (mi_geq_n 0 (List.length l) n l) then find_n ub (n+1) n
        else find_n ub (n+1) high in

    let n_ci = find_n ub init_N serv_state.commitIndex in
    serv_state.commitIndex <- n_ci; ()

(* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *

                           MAIN SERVER FUNCTIONS

 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *)

let read_neighboring_ips port_num =
  let ip_regex = "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*" in
  let rec process_file f_channel =
    try
      let line = Pervasives.input_line f_channel in
      let _ = Str.search_forward (Str.regexp ip_regex) line 0 in
      let ip_str = Str.matched_string line in
      let ip_len = String.length ip_str in
      let port_int = int_of_string (Str.string_after line (ip_len + 1)) in
      let new_ip = (ip_str, port_int) in
      if new_ip <> ( Unix.string_of_inet_addr (get_my_addr ()), port_num) then
        let updated_ips = new_ip::serv_state.neighboringIPs in
        serv_state.neighboringIPs <- updated_ips;
      else
        ();
      process_file f_channel
    with
    | End_of_file -> Pervasives.close_in f_channel; ()
  in
  process_file (Pervasives.open_in "ips.txt")

let req_request_vote ballot oc =
    let json =
      "{\"type\": \"vote_req\",\"term\": " ^ (string_of_int ballot.term) ^",\"candidate_id\": \"" ^ ballot.candidate_id ^ "\",\"last_log_index\": " ^ (string_of_int ballot.last_log_index) ^ ",\"last_log_term\": " ^ (string_of_int ballot.last_log_term) ^ "}"
    in send_msg json oc

(* [res_request_vote msg oc] handles receiving a vote request message *)
let res_request_vote msg oc =
    let candidate_id = msg |> member "candidate_id" |> to_string in
    let continue = match serv_state.votedFor with
                    | None -> true
                    | Some id -> print_endline id; print_endline candidate_id; id=candidate_id in
    let otherTerm = msg |> member "term" |> to_int in
    let last_log_term = msg |> member "last_log_term" |> to_int in
    let last_log_index = msg |> member "last_log_index" |> to_int in
    let vote_granted = continue && otherTerm >= serv_state.currentTerm in
    if (vote_granted) then serv_state.votedFor <- (Some candidate_id);
    let json =
          "{\"type\": \"vote_res\", \"current_term\": " ^ (string_of_int serv_state.currentTerm) ^ ",\"vote_granted\": " ^ (string_of_bool vote_granted) ^ "}"
         in send_msg json oc
    (* match serv_state.lastEntry with
    | Some log ->
        let curr_log_ind = log.index in
        let curr_log_term = log.entryTerm in
        let vote_granted = continue && otherTerm >= serv_state.currentTerm &&
        last_log_index >= curr_log_ind && last_log_term >= curr_log_term in
        let json =
          "{\"current_term\": " ^ (string_of_int serv_state.currentTerm) ^ ",\"vote_granted\": " ^ (string_of_bool vote_granted) ^ "}"
         in send_msg json oc
    | None -> failwith "kek" *)

let send_heartbeats () =
    let lst_o = List.map (fun (ip, chans) -> chans) !channels in
    let rec send_to_ocs lst =
      match lst with
      | (ic, oc)::t ->
        begin
          print_endline "in send heartbeat match";
          let start_timer oc_in =
          Lwt.on_termination (Lwt_unix.sleep serv_state.heartbeat) (fun () -> send_heartbeat oc_in ())
          in
          ignore (Thread.create start_timer oc); send_to_ocs t;
        end
      | [] -> () in
    print_endline "number of ocs";
    print_endline (string_of_int (List.length lst_o));
    let id_of_oc occ =
    match (List.find_opt (fun (_, (_, o)) -> o == occ) (!channels)) with
    | Some (idd, (i, oo)) -> idd
    | None -> "" in
    List.iter (fun (oc, rpc) -> req_append_entries rpc (id_of_oc oc) oc; ()) !get_ae_response_from;
    send_to_ocs lst_o

(* [act_all ()] is a simple check that all servers perform regularly, regardless
 * of role. It should be called at the start of every iteration of one of the
 * act functions for roles *)
let act_all () =
    let la = serv_state.lastApplied in
    if serv_state.commitIndex > la then
    (serv_state.lastApplied <- la + 1); ()

let process_leader_death () =

    print_endline serv_state.leader_id;
    print_endline ("MU!!!");
    let l_id = serv_state.leader_id in
    if l_id <> "" then
        let ip_regex = "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*" in
        let port_regex = "[0-9]*" in
        let _ = Str.search_forward (Str.regexp ip_regex) l_id 0 in
        let ip = Str.matched_string l_id in
        print_endline("SDkjfaldsjfkalsdjf"^ip);
        let _ = Str.search_forward (Str.regexp port_regex) l_id 0 in
        let ip_len = String.length ip in
        print_endline("SAAAAAAAADkjfaldsjfkalsdjf"^(Str.string_after l_id (ip_len + 1)));

        let port = int_of_string (Str.string_after l_id (ip_len + 1)) in

        serv_state.neighboringIPs <- List.filter (fun (i,p) -> i <> ip || p <> port) serv_state.neighboringIPs;
        print_endline ("MUHWUHWUHWUHWHU");
        print_endline (string_of_int (List.length serv_state.neighboringIPs));
        channels := List.remove_assoc l_id !channels;
        print_endline (string_of_int (List.length !channels));
        serv_state.leader_id <- ""; ()

(* [start_election ()] starts the election for this server by incrementing its
 * term and sending RequestVote RPCs to every other server in the clique *)
let rec start_election () =
    print_endline "election started!";
    (* increment term and vote for self *)
    let curr_term = serv_state.currentTerm in
    serv_state.currentTerm <- curr_term + 1;
    serv_state.votedFor <- (Some serv_state.id);
    vote_counter := 1;
    let neighbors = serv_state.neighboringIPs in
    (* ballot is a vote_req *)
    let ballot = {
        term = serv_state.currentTerm;
        candidate_id = serv_state.id;
        last_log_index = get_p_log_idx ();
        last_log_term = get_p_log_term ();
    } in
    print_endline "sending rpcs...";
    send_rpcs (req_request_vote ballot);

(* [act_leader ()] executes all leader responsibilities, namely sending RPCs
 * and listening for client requests
 *
 * if a leader receives a client request, they will process it accordingly *)
and act_leader () =
    (* start thread to periodically send heartbeats *)
    print_endline "act leader";
    update_commit_index ();
    act_all();
    print_endline ("my heartbeat timer: " ^ string_of_float (serv_state.heartbeat));
    send_heartbeats (); ()
and init_leader () =
    let rec build_match_index build ips =
        match ips with
        | [] -> serv_state.matchIndexList <- build; ()
        | (inum,port)::t ->
            let nbuild = (inum^(string_of_int port), 0)::build in
            build_match_index nbuild t in

    let rec build_next_index build ips n_idx =
        match ips with
        | [] -> serv_state.nextIndexList <- build; ()
        | (inum,port)::t ->
            let nbuild = (inum^(string_of_int port), n_idx)::build in
            build_match_index nbuild t in

    print_endline "init leader";
    build_match_index [] serv_state.neighboringIPs;
    let n_idx = (get_p_log_idx ()) + 1 in
    build_next_index [] serv_state.neighboringIPs n_idx;
    act_leader ();

(* [act_candidate ()] executes all candidate responsibilities, namely sending
 * vote requests and ending an election as a winner/loser/stall
 *
 * if a candidate receives a client request, they will reply with an error *)
and act_candidate () =
    (* if the candidate is still a follower, then start a new election
     * otherwise terminate. *)
    print_endline "act candidate";
    print_endline ("my heartbeat " ^ (string_of_float serv_state.heartbeat));
    act_all ();
    let check_election_complete () =
        (* if false, then election has not completed, so start new election.
         * Otherwise if true, then don't do anything (equiv of cancelling timer)
         *)
        print_endline (string_of_bool (serv_state.role = Candidate ));
        if serv_state.role = Candidate
        then begin
                serv_state.votedFor <- None;
                Lwt.on_termination (Lwt_unix.sleep serv_state.heartbeat) (fun () -> act_candidate ())
            end
        else () in

    (* call act_candidate again if timer runs out *)
    start_election ();
    (* continuously check if election has completed and
     * listen for responses to the req_votes *)
    print_endline (string_of_int (List.length serv_state.neighboringIPs));
    if ((List.length serv_state.neighboringIPs)-num_clients)<=1 then win_election ();
    Lwt.on_termination (Lwt_unix.sleep serv_state.heartbeat) (fun () -> check_election_complete ())

and init_candidate () =
    act_candidate ()

(* [act_follower ()] executes all follower responsibilities, namely starting
 * elections, responding to RPCs, and redirecting client calls to the leader
 *
 * if a follower receives a client request, they will send it as a special RPC
 * to the leader, and then receive the special RPC and reply back to the client
 *)
and act_follower () =
    print_endline "act follower";
    print_endline ("my heartbeat " ^ (string_of_float serv_state.heartbeat));
    serv_state.role <- Follower;

    act_all ();
    (* check if the timeout has expired, and that it has voted for no one *)
    print_endline "hearbteat for";
    print_endline (string_of_bool serv_state.received_heartbeat);
    print_endline "voted for";
    print_endline (string_of_bool (serv_state.votedFor = None));
    if (serv_state.votedFor = None && serv_state.received_heartbeat = false)
    then begin
            process_leader_death ();
            serv_state.role <- Candidate;
            init_candidate ()
        end
    (* if condition satisfied, continue being follower, otherwise start elec *)
    else begin
            serv_state.received_heartbeat <- false;
            Lwt.on_termination (Lwt_unix.sleep (serv_state.heartbeat)) (fun () -> act_follower ())
        end

and init_follower () =
    print_endline "init follower";
    Lwt.on_termination (Lwt_unix.sleep serv_state.heartbeat) (fun () -> (act_follower ()));

(* [win_election ()] transitions the server from a candidate to a leader and
 * executes the appropriate actions *)
and win_election () =
    print_endline "ayyyy";
    (* transition to Leader role *)
    serv_state.role <- Leader;
    (* send heartbeats *)
    init_leader ()

(* [lose_election ()] transitions the server from a candidate to a follower
 * and executes the appropriate actions *)
and lose_election () =
    (* transition to Follower role *)
    serv_state.role <- Follower;
    act_follower ()

(* [terminate_election ()] executes when timeout occurs in the middle of an
 * election with no resolution (i.e. no one wins or loses) *)
and terminate_election () =
    start_election ()

let rec id_from_oc cl oc =
    match cl with
    | [] -> None
    | (ip, (_, oc2))::t -> if (oc == oc2) then Some ip else id_from_oc t oc

(* [handle_precheck t] checks the term of the sending server and updates this
 * server's term if it is outdated; also immediately reverts to follower role
 * if not already a follower *)
let handle_precheck t =
    let b = serv_state.role = Candidate || serv_state.role = Leader in
    if t > serv_state.currentTerm && b then
        (serv_state.currentTerm <- t;
        (init_follower ());())
    else if t > serv_state.currentTerm then
        serv_state.currentTerm <- t;()

let handle_ae_req msg oc =
    let ap_term = msg |> member "ap_term" |> to_int in
    let leader_id = msg |> member "leader_id" |> to_string in
    let prev_log_index = msg |> member "prev_log_index" |> to_int in
    let prev_log_term = msg |> member "prev_log_term" |> to_int in
    let entries = msg |> member "entries" |> to_string |> json_es in
    let leader_commit = msg |> member "leader_commit" |> to_int in

    handle_precheck ap_term;

    let success_bool =
        if ap_term < serv_state.currentTerm then false (* 1 *)
        else if mismatch_log serv_state.log prev_log_index prev_log_term then false (* 2 *)
        else true
    in
    let ae_res = {
        success = success_bool;
        current_term = serv_state.currentTerm;
    } in
    (* TODO do we still process conflicts and append new entries if success = false???? *)
    process_conflicts entries; (* 3 *)
    append_new_entries entries; (* 4 *)
    if leader_commit > serv_state.commitIndex then
        (let new_commit = min leader_commit (get_p_log_idx ()) in
        serv_state.commitIndex <- new_commit); (* 5 *)
    res_append_entries ae_res oc

let handle_ae_res msg oc =
    let current_term = msg |> member "current_term" |> to_int in
    let success = msg |> member "success" |> to_bool in

    let responder_id = (
        match (id_from_oc !channels oc) with
        | None -> failwith "not possible"
        | Some x -> x
    ) in

    handle_precheck current_term;

    (* TODO we may need to modify these functions depending on the request that
     * this is in response to *)
    if success then (update_match_index oc; update_next_index oc;);
    if (not success) then (force_conform responder_id);

    (* here we identify the request that this response is to via the first tuple
     * whose oc matches [oc]; then we remove it if success is true *)

    get_ae_response_from := (List.remove_assq oc !get_ae_response_from);

    let s_count = (if success then !success_count + 1 else !success_count) in
    let t_count = !response_count + 1 in

    (* if we have a majority of followers allowing the commit, then commit *)
    if s_count > (((List.length serv_state.neighboringIPs)-num_clients) / 2) then
        ((* reset counters *)
        response_count := 0; success_count := 0;
        (* commit to log by incrementing the commitIndex *)
        (* TODO VERY IMPORTANT: HOW DO WE IGNORE EXTRA RESPONSES AFTERWARDS?
         * aka we don't want to add to the response_count bc they could be handling
         * the next round of AEres, so we need to track who has responded to which AEreqs *)
        let old_ci = serv_state.commitIndex in
        serv_state.commitIndex <- old_ci + 1; ())
    else if t_count = ((List.length serv_state.neighboringIPs)-num_clients) then
        ((* reset reset counters *)
        response_count := 0; success_count := 0;
        ()) (* TODO notify client of failure *)
    else () (* do nothing basically *)

let handle_vote_req msg oc =
    (* at this point, the current leader has died, so need to delete leader *)
    process_leader_death ();
    print_endline "this is vote req";
    print_endline (string_of_bool (serv_state.role = Follower));
    let t = msg |> member "term" |> to_int in
    handle_precheck t;
    res_request_vote msg oc; ()

(* [handle_vote_res msg] handles receiving a vote response message *)

let handle_vote_res msg =
    print_endline "handling vote res!";
    let currTerm = msg |> member "current_term" |> to_int in
    let voted = msg |> member "vote_granted" |> to_bool in
    handle_precheck currTerm;
    if voted then vote_counter := !vote_counter + 1;
    print_endline ("num clients " ^ (string_of_int num_clients));
    if serv_state.role <> Leader && !vote_counter >
        ((((List.length serv_state.neighboringIPs)) - num_clients) / 2)
            then win_election ()

(*[process_heartbeat msg] handles receiving heartbeats from the leader *)
let process_heartbeat msg =
    let l_id = msg |> member "leader_id" |> to_string in
    let leader_commit = msg |> member "leader_commit" |> to_int in

    if leader_commit > serv_state.commitIndex
    then begin
            serv_state.leader_id <- l_id;
            serv_state.commitIndex <- min leader_commit (get_p_log_idx ())
        end
    else serv_state.leader_id <- l_id; serv_state.votedFor <- None

let handle_client_as_leader msg =
    failwith "
    1. parse the value field, leader append to own log -- see mli
     (leader's current term & list.length for index)
    2. call req append entries"

let update_output_channels oc msg =
    print_endline "as;flkajsd";
    let ip = msg |> member "ip" |> to_string in
    let chans = List.find (fun (_, (_, orig_oc)) -> orig_oc == oc) !channels in
    let c_lst = List.filter (fun (_, (_, orig_oc)) -> orig_oc != oc) !channels in
    print_endline (ip^"EVERYTHING IS OK");
    channels := (ip, snd chans)::c_lst

let handle_message msg oc =
    print_endline ("received: "^msg);
    serv_state.received_heartbeat <- true;
    let msg = Yojson.Basic.from_string msg in
    let msg_type = msg |> member "type" |> to_string in
    match msg_type with
    | "oc" -> update_output_channels oc msg; ()
    | "heartbeat" -> print_endline "this is a heart"; process_heartbeat msg; ()
    | "sendall" -> send_heartbeats (); ()
    | "vote_req" -> handle_vote_req msg oc; ()
    | "vote_res" -> handle_vote_res msg; ()
    | "appd_req" -> begin
                        print_endline "received app";
                        if serv_state.role = Candidate
                        then ignore (lose_election ());
                        handle_ae_req msg oc;
                        ()
                    end
    | "appd_res" -> handle_ae_res msg oc; ()
    | "find_leader" ->
        let res_id = if (serv_state.role = Leader) then serv_state.id
        else serv_state.leader_id in
        let res = "{\"type\": \"find_leader_res\", \"leader\": \""^res_id^"\"}" in
        send_msg res oc; ()
    | "find_leader_res" -> print_endline "hellooooooooooooo!"; leader_ip := (msg |> member "leader" |> to_string)
    | "client" ->
        (* TODO redirect client to Leader *)
        if serv_state.role <> Leader then
            (print_endline serv_state.leader_id; ())
        else
            (* create the append_entries_rpc *)
            (* using 0 to indicate no previous entry *)
            let rpc = create_rpc msg in

            let output_channels_to_rpc = List.map (fun (_,(_,oc)) -> (oc, rpc)) !channels in
            get_ae_response_from := (!get_ae_response_from @ output_channels_to_rpc);

            (* add the request to the list such that early requests are at the
             * beginning of the list *)
            ae_req_to_count := (!ae_req_to_count @ [(rpc, 0)]); ()
    | _ -> ()

(* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
 *                                                                           *
 *                                                                           *
 * EVERYTHING AFTER THIS POINT IS NETWORKING/SERVER STUFF WHICH IS GENERALLY *
 * SEPARATE FROM RAFT IMPLEMENTATION DETAILS                                 *
 *                                                                           *
 *                                                                           *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *)

let rec handle_connection ic oc () =
    Lwt_io.read_line_opt ic >>=
    (fun (msg) ->
        match msg with
        | (Some m) ->
            print_endline "wow!";
            handle_message m oc;
            (handle_connection ic oc) ();
        | None -> begin Lwt_log.info "Connection closed." >>= return end)

let send_ip oc =
    let json =
    "{" ^
        "\"type\": \"oc\"," ^
        "\"ip\": \"" ^ serv_state.id ^ "\"" ^
    "}"
    in
    send_msg json oc

(* [init_server ()] starts up this server as a follower and anticipates an
 * election. That is, this should ONLY be called as soon as the server begins
 * running (and after it has set up connections with all other servers) *)
let init_server () =

    List.iter (fun (_,(_,oc)) -> send_ip oc; ()) !channels;
    change_heartbeat ();
    let chans = List.map (fun (ips, ic_ocs) -> ic_ocs) !channels in
    List.iter
    (fun (ic, oc) -> Lwt.on_failure (handle_connection ic oc ())
        (fun e -> Lwt_log.ign_error (Printexc.to_string e));) chans;
    print_endline "after list";
    init_follower ();
    print_endline "rigth before"

let accept_connection conn =
   print_endline "accepted";
    let fd, _ = conn in
    let ic = Lwt_io.of_fd Lwt_io.Input fd in
    let oc = Lwt_io.of_fd Lwt_io.Output fd in
    let otherl = !channels in
    let ip = "" in
    channels := ((ip, (ic, oc))::otherl);
    let iplistlen = List.length (serv_state.neighboringIPs) in
    print_endline (string_of_int iplistlen);
    if (List.length !channels) = iplistlen then init_server ();
    Lwt_log.info "New connection" >>= return

(* this will be filled in the beginning *)

let rec query_server ic oc =
  try
    print_string  "Request : ";
    print_string (string_of_float (Unix.time ()));
    flush Pervasives.stdout;
    (* output_string oc ((input_line Pervasives.stdin)^"\n") ; *)
    output_string oc (("{\"type\":\"appd_res\"}")^"\n"); (*make client automatically do stuff. can reuse in server code*)
    flush oc;
    let r = input_line ic
    in Printf.printf "Response : %s\n\n" r;
    flush oc;
    if r = "END" then (Unix.shutdown_connection ic; raise Exit);

  with
    | Exit -> exit 0
    | exn -> Unix.shutdown_connection ic ; raise exn

let create_socket portnum () =
    let open Lwt_unix in
    let sock = socket PF_INET SOCK_STREAM 0 in
    bind sock @@ ADDR_INET(listen_address, portnum);
    listen sock backlog;
    sock

let main_client address portnum is_server =
    try
        let sockaddr = Lwt_unix.ADDR_INET(Unix.inet_addr_of_string address, portnum) in
        print_endline "main client";
        print_endline (string_of_int (List.length (serv_state.neighboringIPs)));
        let%lwt ic, oc = Lwt_io.open_connection sockaddr in
        let otherl = !channels in
             let ip = "" in
             channels := ((ip, (ic, oc))::otherl);
             let iplistlen = (List.length (serv_state.neighboringIPs))-1 in

             if (List.length !channels)=iplistlen && is_server then (print_endline "connections good"; init_server ()) else print_endline "not good";

        Lwt_log.info "added connection" >>= return
    with
        Failure("int_of_string") -> Printf.printf "bad port number";
                                        exit 2 ;;

let establish_connections_to_others is_server =
    print_endline "establish";
    let ip_ports_list = serv_state.neighboringIPs in
    let rec get_connections lst =
        match lst with
        | [] -> ()
        | (ip_addr, portnum)::t ->
        begin
            print_endline "in begin";
            main_client ip_addr portnum is_server;
            get_connections t;
        end
    in get_connections ip_ports_list

let create_server sock =
    let rec serve () =
        print_endline "i am waiting for connections";
        Lwt_unix.accept sock >>= accept_connection >>= serve
    in serve


let rec st port_num =
    serv_state.id <- ((Unix.string_of_inet_addr (get_my_addr ())) ^ ":" ^ (string_of_int port_num));
    read_neighboring_ips port_num;
    establish_connections_to_others true;
    print_endline "i finished";
    let sock = create_socket port_num () in
    let serve = create_server sock in
    print_endline "running";
    Lwt_main.run @@ serve ();;

let _ = Random.self_init()

(* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
 *                                                                           *
 *                                                                           *
 * WEBSOCKET FOR A CLIENT IMPL                                               *
 *                                                                           *
 *                                                                           *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *)

let rec send_msg_from_client msg =
    if (!leader_ip="") then
        begin
            let chans = List.map (fun (ips, ic_ocs) -> ic_ocs) !channels in
            List.iter
            (fun (ic, oc) -> Lwt.on_failure (handle_connection ic oc ())
                (fun e -> Lwt_log.ign_error (Printexc.to_string e));) chans;
            let find_ip_json = "{\"type\":\"find_leader\"}" in
            match List.nth_opt !channels 0 with
            | Some (ip, (ic, oc)) -> send_msg find_ip_json oc; ()
            | None -> ()
        end
    else print_endline !leader_ip; ()

let handler
    (conn : Conduit_lwt_unix.flow * Cohttp.Connection.t)
    (req  : Cohttp_lwt_unix.Request.t)
    (body : Cohttp_lwt_body.t) =
  if !conn_ws = None then conn_ws := Some conn;
  if !req_ws = None then req_ws := Some req;
  if !body_ws = None then body_ws := Some body;
  let open Frame in
  Lwt_io.eprintf
        "[CONN] %s\n%!" (Cohttp.Connection.to_string @@ snd conn)
  >>= fun _ ->
(*   let headers = req |> Cohttp.Request.headers |> Cohttp.Header.to_string in
  print_endline headers; *)
  let uri = Cohttp.Request.uri req in
  match Uri.path uri with
  | "/" ->
    Lwt_io.eprintf "[PATH] \n%!"
    >>= fun () ->
    Cohttp_lwt_body.drain_body body
    >>= fun () ->
    Websocket_cohttp_lwt.upgrade_connection req (fst conn) (
        fun f ->
            match f.opcode with
            | Frame.Opcode.Close ->
                Printf.eprintf "[RECV] CLOSE\n%!"
            | _ ->
                (* do this shit here where u set append entries i guess *)
                send_msg_from_client f.content;
                Printf.eprintf "[RECV] %s\n%!" f.content
    );
    >>= fun (resp, body, frames_out_fn) ->
    (* send a message to the client *)
    let _ =
            (* replace msg with latest value from server *)
            let msg = Printf.sprintf "connected!" in
            Lwt_io.eprintf "[SEND] %s\n%!" !res_client_msg
            >>= fun () ->
            Lwt.wrap1 frames_out_fn @@
                Some (Frame.create ~content:msg ())
            >>= Lwt.return
    in
    Lwt.return (resp, (body :> Cohttp_lwt_body.t))
  | _ ->
    Lwt_io.eprintf "[PATH] Catch-all\n%!"
    >>= fun () ->
    Cohttp_lwt_unix.Server.respond_string
        ~status:`Not_found
        ~body:(Sexplib.Sexp.to_string_hum (Cohttp.Request.sexp_of_t req))
        ()

let start_websocket host port_num () =
  read_neighboring_ips port_num;
  establish_connections_to_others false;
  let sock = create_socket (port_num+1) () in
  let serve = create_server sock in
  let conn_closed (ch,_) =
    Printf.eprintf "[SERV] connection %s closed\n%!"
      (Sexplib.Sexp.to_string_hum (Conduit_lwt_unix.sexp_of_flow ch))
  in
  Lwt_io.eprintf "[SERV] Listening for HTTP on port_num %d\n%!" port_num >>= fun () ->
  Cohttp_lwt_unix.Server.create
    ~mode:(`TCP (`Port port_num))
    (Cohttp_lwt_unix.Server.make ~callback:handler ~conn_closed ());
  Lwt_main.run @@ serve ()

let start_client () =
    start_websocket (Unix.string_of_inet_addr (get_my_addr ())) 3001 ()

(* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
 *                                                                           *
 *                                                                           *
 * END WEBSOCKET                                                             *
 *                                                                           *
 *                                                                           *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *)

