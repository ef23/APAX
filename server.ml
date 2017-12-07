open Lwt
open Websocket
open Websocket_cohttp_lwt
open Log
open Request_vote_rpc
open Append_entries_rpc
open Yojson.Basic.Util

type role = | Follower | Candidate | Leader

type ip = (string*int) list (* (ip * port) *)
type next_index = (string*int) list (* (id * next index) *)
type match_index = (string*int) list (* (id * match index) *)

type state = {
    mutable id : string;
    mutable leader_id: string;
    mutable role : role;
    mutable curr_term : int;
    mutable voted_for : string option;
    mutable log : (int * entry) list; (* index * entry list *)
    mutable commit_index : int;
    mutable last_applied : int;
    mutable heartbeat : float;
    mutable neighboring_ips : ip;
    mutable next_index_lst : next_index;
    mutable match_index_lst : match_index;
    mutable received_heartbeat : bool;
    mutable started : bool;
    mutable is_server : bool;
}

let get_ae_response_from = ref []
let index_responses = ref []

(* the lower range of the election timeout, in th is case 150-300ms*)
let generate_heartbeat () =
    let lower = 5.150 in
    let range = 2.400 in
    let timer = (Random.float range) +. lower in
    print_endline ("timer:"^(string_of_float timer));
    timer

let serv_state = {
    id = "";
    leader_id = "";
    role = Follower;
    curr_term = 0;
    voted_for = None;
    log = [];
    commit_index = 0;
    last_applied = 0;
    heartbeat = 0.;
    neighboring_ips = [];
    next_index_lst = [];
    match_index_lst = [];
    received_heartbeat = false;
    started = false;
    is_server = true;
}

(* [get_my_addr ()] gets the current address of this host *)
let get_my_addr () =
    (Unix.gethostbyname(Unix.gethostname())).Unix.h_addr_list.(0)

(* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *

                           NON-STATE SERVER FIELDS

 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *)

(* keeps track of votes in the election *)
let vote_counter = ref 0

(* a string * (input_channel * output_channel) list
 * mapping each server ID to its ic and oc *)
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

(* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *

                            HELPER FUNCTIONS

 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *)

(* [id_from_oc cl oc] takes an output channel [oc] and channels+id list [cl] and
 * finds the id corresponding to the channel [oc] *)
let rec id_from_oc cl oc =
    match cl with
    | [] -> None
    | (ip, (_, oc2))::t -> if (oc == oc2) then Some ip else id_from_oc t oc

(* [last_entry ()] is the last entry added to the server's log
 * The log must be sorted in reverse chronological order *)
let last_entry () =
    match serv_state.log with
    | [] -> None
    | (_, e)::_ -> Some e

(* [get_p_log_idx ()] returns the 1-based index of the most recently added
 * entry in the log *)
let get_p_log_idx () =
    match last_entry () with
    | None -> 0
    | Some e -> e.index

(* [get_p_log_term ()] returns the 1-based term of the most recently added
 * entry in the log *)
let get_p_log_term () =
    match last_entry () with
    | None -> 0
    | Some e -> e.entry_term

(* [full_addr_str p] returns the concatenation of this server's IP and port *)
let full_addr_str port_num =
    Unix.string_of_inet_addr (get_my_addr ()) ^ ":" ^ (string_of_int port_num)

(* [change_heartbeat ()] changes the current server's heartbeat to a randomized,
 * value on a fixed interval *)
let change_heartbeat () =
    let new_heartbeat = generate_heartbeat () in
    serv_state.heartbeat <- new_heartbeat

(* [update_neighbors ips id] updates this server's neighboring IPs list with
 * [ips] TODO more on this later *)
let update_neighbors ips id =
    serv_state.neighboring_ips <- ips;
    serv_state.id <- id

(* [send_msg str oc] sends the string message [msg] to the server connected by
 * output channel [oc] *)
let send_msg str oc =
    print_endline ("sending: "^str);
    ignore (Lwt_io.write_line oc str); Lwt_io.flush oc

(* [stringify_e e] converts an entry record [e] to a string *)
let stringify_e (e:entry): string =
  let json =
    "{" ^
      "\"value\":" ^ (string_of_int e.value) ^ "," ^
      "\"entry_term\":" ^ (string_of_int e.entry_term) ^ "," ^
      "\"index\":" ^ (string_of_int e.index) ^
    "}"
  in json

(* [nindex_from_id id] takes a server id [id] and the next_index_lst and
 * finds the nextIndex of server [id] *)
let nindex_from_id id =
    match List.assoc_opt id serv_state.next_index_lst with
    | None -> -1
    | Some i -> i

(* [oc] is the output channel to send to a server with an ip [ip] *)
let req_append_entries (msg : append_entries_req) (ip : string) oc =
    let string_entries = List.map (fun x -> stringify_e x) msg.entries in
    let entries_str = List.fold_right (fun x y -> x ^ "," ^ y) string_entries "" in
    let final_entries_str = "[" ^ (String.sub entries_str 0 ((String.length entries_str) - 1)) ^ "]" in
    (*let entries_str = (List.fold_left (fun a e -> (stringify_e e) ^ "\n" ^ a) "" msg.entries) in print_endline("ENTRIES STR " ^ entries_str);*)
    let json =
       "{" ^
        "\"type\": \"appd_req\"," ^
        "\"ap_term\":" ^ (string_of_int msg.ap_term) ^"," ^
        "\"leader_id\":" ^ "\"" ^ (msg.leader_id) ^ "\"," ^
        "\"prev_log_index\": " ^ (string_of_int msg.prev_log_index) ^ "," ^
        "\"prev_log_term\": " ^ (string_of_int msg.prev_log_term) ^ "," ^
        "\"entries\":" ^ final_entries_str
        ^ "," ^
        "\"leader_commit\":" ^ (string_of_int msg.leader_commit) ^
      "}"
    in
    print_endline ("ENTRIES LENGTH LIST"^string_of_int (List.length msg.entries));
    send_msg json oc

(*[res_append_entries ae_res oc] sends the stringified append entries response
 * [ae_res] to the output channel [oc]*)
let res_append_entries (ae_res:append_entries_res) oc =
    if (not serv_state.is_server) then Lwt.return(()) else
    let json =
      "{" ^
        "\"type\":" ^ "\"appd_res\"" ^ "," ^
        "\"success\":" ^ string_of_bool ae_res.success ^ "," ^
        "\"curr_term\":"  ^ string_of_int ae_res.curr_term ^
      "}"
    in
    send_msg json oc

(* [json_es entries] should return a list of entries parsed from the string [entries].
 * - requires: [entries] has at least one entry in it
 *)
let json_es (entries): entry list =
    let json = Yojson.Basic.Util.to_list entries in
    let assoc_list = List.map (fun x -> Yojson.Basic.Util.to_assoc x) (json) in

    (*let entries_str_lst =  Str.split (Str.regexp "[\n]+") entries in*)
    let extract_record e =
        print_endline " this is before parsing in extract";
        let value = Yojson.Basic.Util.to_int (List.assoc "value" e) in
        print_endline ("value " ^ (string_of_int value));
        let entry_term = Yojson.Basic.Util.to_int (List.assoc "entry_term" e) in
        print_endline ("entry term " ^ (string_of_int entry_term));
        let ind = Yojson.Basic.Util.to_int (List.assoc "index" e) in
        print_endline ("ind" ^ string_of_int (ind));
        {
            value = value;
            entry_term = entry_term;
            index = ind;
        }
    in
    let ocaml_entries = List.map extract_record assoc_list in
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
    if (List.length my_log <= 1) then false
    else if prev_log_index > (List.length my_log + 1) then true
    else
        match (List.find_opt (fun (i,e) -> i = prev_log_index) my_log) with
        | None -> true
        | Some (_,e) -> if e.entry_term = prev_log_term then (print_endline "terms"; false) else true

(* [process_conflicts entries] goes through the server's log and removes entries
 * that conflict (same index different term) with those in [entries] *)
let process_conflicts entries =
    (* [does_conflict e1 e2] returns true if e1 has a different term than e2
     * -requires e1 and e2 to have the same index *)
    let does_conflict log_e new_e =
        if log_e.entry_term = new_e.entry_term then false else true in

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

let rec print_lst () = function
    | [] -> print_endline "endlist"
    | h::t -> match h with
        | {value=v; entry_term = e; index = i} -> print_endline ("("^(string_of_int v)^", "^(string_of_int e)^", "^(string_of_int i)^")"); print_lst () t

(* [send_heartbeat oc ()] sends one heartbeat to the server corresponding to
 * output channel [oc] *)
let rec send_heartbeat oc () =
    print_lst () (List.map (fun (x,y) -> y) serv_state.log);
    ignore (Lwt_io.write_line oc (
        "{" ^
        "\"type\":\"heartbeat\"," ^
        "\"leader_id\":" ^ "\"" ^ serv_state.id ^ "\"" ^ "," ^
        "\"curr_term\":" ^ string_of_int serv_state.curr_term ^ "," ^
        "\"prev_log_index\": " ^ (get_p_log_idx () |> string_of_int) ^ "," ^
        "\"prev_log_term\": " ^ (get_p_log_term () |> string_of_int) ^ "," ^
        "\"entries\": \"\"," ^
        "\"leader_commit\":" ^ string_of_int serv_state.commit_index ^
        "}"));
    ignore (Lwt_io.flush oc);
    let id_of_oc occ =
        match (List.find_opt (fun (_, (_, o)) -> o == occ) (!channels)) with
        | Some (idd, (i, oo)) -> idd
        | None -> "" in
        List.iter (fun (oc, rpc) -> req_append_entries rpc (id_of_oc oc) oc; ())  !get_ae_response_from; print_endline ("LENGHT"^string_of_int (List.length !get_ae_response_from));
    Lwt.on_termination (Lwt_unix.sleep serv_state.heartbeat) (fun () -> send_heartbeat oc ())

(* [create_rpc msg i t] creates an rpc to be sent to the servers based on the [msg]
 * containing the value the client wants to add as well as the leader's term and
 * the index of the entry in the log. Only the leader should call this function
 *)
let create_rpc msg id p_log_idx p_log_term =
    (* let p_log_idx = get_p_log_idx () in *)
    (* let p_log_term = get_p_log_term () in *)

    let e = [] in
    let next_index = nindex_from_id id in
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
        ap_term = serv_state.curr_term;
        leader_id = serv_state.id;
        prev_log_index = p_log_idx;
        prev_log_term = p_log_term;
        entries = entries_;
        leader_commit = serv_state.commit_index
    }
(* [force_conform id] forces server with id [id] to conform to the leader's log
 * if there is an inconsistency between the logs (aka the AERes success would be
 * false) *)
let force_conform id =
    let ni = nindex_from_id id in
    (* update the nextIndex for this server to be ni - 1 *)

    let new_indices = List.filter (fun (lst_ip, _) -> lst_ip <> id) serv_state.next_index_lst in
    serv_state.next_index_lst <- (id, ni-1)::new_indices;
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
            | [] -> failwith "this should literally never happen"
            | (s,i)::t ->
                if s = idx then
                    (* note: nextIndex - matchIndex > 1 if and only if a new
                     * leader comes into power with a significantly larger log
                     * which is a result of unifying a network partition, which
                     * is NOT a feature that we support *)
                    (let n_matchi = List.length serv_state.log in
                    serv_state.match_index_lst <- ([(s,n_matchi)]@t@build); ())
                else apply ((s,i)::build) t idx
        in
        apply [] serv_state.match_index_lst id; ()

(* [update_next_index ] is only used by the leader *)
let update_next_index oc =
    let (ip, (_,_)) = List.find (fun (_, (_, list_oc)) -> oc == list_oc) !channels in
    let new_indices = List.filter (fun (lst_ip, _) -> lst_ip <> ip) serv_state.next_index_lst in
    serv_state.next_index_lst <- (ip, List.length serv_state.log)::new_indices

(* [update_commit_index ()] updates the commit_index for the Leader by finding an
 * N such that N > commit_index, a majority of matchIndex values >= N, and the
 * term of the Nth entry in the leader's log is equal to curr_term *)
let update_commit_index () =
    (* upper bound on N, which is the index of the last entry *)
    let ub = get_p_log_idx () in
    let init_N = serv_state.commit_index + 1 in

    (* find whether the majority of followers have matchIndex >= N *)
    let rec mi_geq_n count total n li =
        match li with
        | [] -> (count > (total / 2))
        | (_,i)::t ->
            if i >= n then mi_geq_n (count+1) total n t
            else mi_geq_n count total n t in

    (* find the highest such n, n <= ub, such that the above function returns true *)
    let rec find_n ub n high =
        let l = serv_state.match_index_lst in
        if n > ub then high
        else if (mi_geq_n 0 (List.length l) n l) then find_n ub (n+1) n
        else find_n ub (n+1) high in

    let old_ci = serv_state.commit_index in
    let n_ci = find_n ub init_N serv_state.commit_index in
    assert (n_ci >= old_ci);
    serv_state.commit_index <- n_ci; ()

let check_majority () =
    let total_num_servers = List.length serv_state.neighboring_ips in
    let index_to_commit =
    match List.find_opt (fun (ind, count) -> count > (total_num_servers/2)) !index_responses with
    | None -> serv_state.commit_index
    | Some (ind, count) -> ind in
    serv_state.commit_index <- index_to_commit

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
        let updated_ips = new_ip::serv_state.neighboring_ips in
        serv_state.neighboring_ips <- updated_ips;
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
    let continue = match serv_state.voted_for with
                    | None -> true
                    | Some id -> print_endline id; print_endline candidate_id; id=candidate_id in
    let otherTerm = msg |> member "term" |> to_int in
    let vote_granted = continue && otherTerm >= serv_state.curr_term in
    if (vote_granted) then serv_state.voted_for <- (Some candidate_id);
    let json =
          "{\"type\": \"vote_res\", \"curr_term\": " ^ (string_of_int serv_state.curr_term) ^ ",\"vote_granted\": " ^ (string_of_bool vote_granted) ^ "}"
         in send_msg json oc
    (* match serv_state.lastEntry with
    | Some log ->
        let curr_log_ind = log.index in
        let curr_log_term = log.entry_term in
        let vote_granted = continue && otherTerm >= serv_state.curr_term &&
        last_log_index >= curr_log_ind && last_log_term >= curr_log_term in
        let json =
          "{\"current_term\": " ^ (string_of_int serv_state.curr_term) ^ ",\"vote_granted\": " ^ (string_of_bool vote_granted) ^ "}"
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

    send_to_ocs lst_o

(* [act_all ()] is a simple check that all servers perform regularly, regardless
 * of role. It should be called at the start of every iteration of one of the
 * act functions for roles *)
let act_all () =
    let la = serv_state.last_applied in
    if serv_state.commit_index > la then
    (serv_state.last_applied <- la + 1); ()

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

        serv_state.neighboring_ips <- List.filter (fun (i,p) -> i <> ip || p <> port) serv_state.neighboring_ips;
        print_endline ("MUHWUHWUHWUHWHU");
        print_endline (string_of_int (List.length serv_state.neighboring_ips));
        channels := List.remove_assoc l_id !channels;
        print_endline (string_of_int (List.length !channels));
        serv_state.leader_id <- ""; ()

(* [start_election ()] starts the election for this server by incrementing its
 * term and sending RequestVote RPCs to every other server in the clique *)
let rec start_election () =
    print_endline "election started!";
    (* increment term and vote for self *)
    let curr_term = serv_state.curr_term in
    serv_state.curr_term <- curr_term + 1;
    serv_state.voted_for <- (Some serv_state.id);
    vote_counter := 1;
    (* ballot is a vote_req *)
    let ballot = {
        term = serv_state.curr_term;
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
        | [] -> serv_state.match_index_lst <- build
        | (inum,port)::t ->
            let nbuild = (inum^":"^(string_of_int port), 0)::build in
            build_match_index nbuild t in

    let rec build_next_index build ips n_idx =
        match ips with
        | [] -> serv_state.next_index_lst <- build
        | (inum,port)::t ->
            let nbuild = (inum^":"^(string_of_int port), n_idx)::build in
            build_next_index nbuild t n_idx in
    print_endline "init leader";
    build_match_index [] serv_state.neighboring_ips;
    let n_idx = (get_p_log_idx ()) + 1 in
    build_next_index [] serv_state.neighboring_ips n_idx;
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
                serv_state.voted_for <- None;
                Lwt.on_termination (Lwt_unix.sleep serv_state.heartbeat) (fun () -> act_candidate ())
            end
        else () in

    (* call act_candidate again if timer runs out *)
    start_election ();
    (* continuously check if election has completed and
     * listen for responses to the req_votes *)
    if (List.length serv_state.neighboring_ips)<=1 then win_election ();
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
    print_lst () (List.map (fun (x,y) -> y) serv_state.log);
    print_endline ("my heartbeat " ^ (string_of_float serv_state.heartbeat));
    serv_state.role <- Follower;

    act_all ();
    (* check if the timeout has expired, and that it has voted for no one *)
    print_endline "hearbteat for";
    print_endline (string_of_bool serv_state.received_heartbeat);
    print_endline "voted for";
    print_endline (string_of_bool (serv_state.voted_for = None));
    if (serv_state.voted_for = None && serv_state.received_heartbeat = false)
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
    if t > serv_state.curr_term && b then
        (serv_state.curr_term <- t;
        (init_follower ());())
    else if t > serv_state.curr_term then
        serv_state.curr_term <- t;()

let handle_ae_req msg oc =
    let ap_term = msg |> member "ap_term" |> to_int in
    let prev_log_index = msg |> member "prev_log_index" |> to_int in
    let prev_log_term = msg |> member "prev_log_term" |> to_int in
    let entries = msg |> member "entries" |> json_es in
    let leader_commit = msg |> member "leader_commit" |> to_int in

    handle_precheck ap_term;

    let success_bool =
        if ap_term < serv_state.curr_term then (print_endline "first is false"; false) (* 1 *)
        else if mismatch_log serv_state.log prev_log_index prev_log_term then false (* 2 *)
        else true
    in
    print_endline (string_of_bool success_bool);
    let ae_res = {
        success = true; (*before was success_bool*)
        curr_term = serv_state.curr_term;
    } in
    (* TODO do we still process conflicts and append new entries if success = false???? *)
    (* right now we only process conflicts, append new entries, and update commit if true *)
    if (success_bool) then
        (process_conflicts entries; (* 3 *)
        append_new_entries entries; (* 4 *)
        if leader_commit > serv_state.commit_index then
        (let new_commit = min leader_commit (get_p_log_idx ()) in
        serv_state.commit_index <- new_commit); (* 5 *)
    );

    res_append_entries ae_res oc

let handle_ae_res msg oc =
    let curr_term = msg |> member "curr_term" |> to_int in
    let success = msg |> member "success" |> to_bool in

    let responder_id = (
        match (id_from_oc !channels oc) with
        | None -> failwith "not possible"
        | Some x -> x
    ) in

    handle_precheck curr_term;

    (* TODO we may need to modify these functions depending on the request that
     * this is in response to *)
    if success then
        begin
            update_match_index oc;
            update_next_index oc
        end;
    if (not success) then (force_conform responder_id);

    (* here we identify the request that this response is to via the first tuple
     * whose oc matches [oc]; then we remove it if success is true *)

    get_ae_response_from := (List.remove_assq oc !get_ae_response_from);

    let servid = match (id_from_oc !channels oc) with
        | None -> "should be impossible"
        | Some s -> s in

    print_endline (servid ^"SERVID"); print_endline (string_of_int (List.length !get_ae_response_from));
    
    if (success) then 
    begin
        match List.find_opt (fun (oc_l, rpc_l) -> oc == oc_l) !get_ae_response_from with
        | None -> ()
        | Some (o,r) ->
            let last_entry_serv_committed =
                begin try (List.hd (r.entries)).index with
                    | _ -> failwith "Impossible. Leader should always have at least one entry to send."
                end in

            let latest_ind_for_server =
                match List.assoc_opt servid serv_state.match_index_lst with
                | None -> (*serv_state.matchIndexList <-
                (servid, if success then last_entry_serv_committed else 0)::serv_state.matchIndexList; 0*)
                failwith "should not occur because we already update match index?"
                | Some i -> i in

            (*index responses is in decreasing log index, and it is (ind of entry, num servers
            that contain that entry)*)
            let num_to_add = match !index_responses with
                | (indd, co)::t -> indd + 1
                | [] -> 1 in

            let rec add_to_index_responses ind_to_add ind_to_stop =
                if (ind_to_add >= ind_to_stop) then ()
                else
                    (index_responses := (ind_to_add, 0)::!index_responses;
                    add_to_index_responses (ind_to_add + 1) ind_to_stop) in

            add_to_index_responses num_to_add (last_entry_serv_committed);

            index_responses := (List.map (fun (ind, count) ->
                            if (ind > latest_ind_for_server && ind <= last_entry_serv_committed)
                            then (ind, (count + 1)) else (ind, count)) !index_responses);

            check_majority ()
    end
    else begin
        force_conform servid;
        let serv_id = match id_from_oc !channels oc with
        | Some id -> id
        | None -> failwith "oc should have corresponding id" in
        let pli = get_p_log_idx () in
        let plt = get_p_log_term () in
        let tuple_to_add = (oc, create_rpc msg serv_id pli plt) in
        get_ae_response_from := !get_ae_response_from @ (tuple_to_add::[]);
        check_majority ()
    end
    
let handle_vote_req msg oc =
    (* at this point, the current leader has died, so need to delete leader *)
    process_leader_death ();
    print_endline "this is vote req";
    print_endline (string_of_bool (serv_state.role = Follower));
    let t = msg |> member "term" |> to_int in
    handle_precheck t;
    ignore (res_request_vote msg oc); ()

(* [handle_vote_res msg] handles receiving a vote response message *)
let handle_vote_res msg =
    print_endline "handling vote res!";
    let currTerm = msg |> member "curr_term" |> to_int in
    let voted = msg |> member "vote_granted" |> to_bool in
    handle_precheck currTerm;
    if voted then vote_counter := !vote_counter + 1;
    if serv_state.role <> Leader && !vote_counter >
        (((List.length serv_state.neighboring_ips)) / 2)
            then win_election ()

(*[process_heartbeat msg] handles receiving heartbeats from the leader *)
let process_heartbeat msg =
    let l_id = msg |> member "leader_id" |> to_string in
    let leader_commit = msg |> member "leader_commit" |> to_int in

    (* if the leader ip that the client server has does not match current
     * leader id, update the leader ip *)
    if (not serv_state.is_server) && !leader_ip <> l_id then leader_ip := l_id;

    if leader_commit > serv_state.commit_index
    then begin
            begin
                match List.assoc_opt serv_state.commit_index serv_state.log with
                | None -> ()
                | Some {value=v} -> res_client_msg := string_of_int v
            end;
            serv_state.leader_id <- l_id;
            serv_state.commit_index <- min leader_commit (get_p_log_idx ())
        end
    else serv_state.leader_id <- l_id; serv_state.voted_for <- None

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
    | "heartbeat" -> print_endline "this is a heart"; print_lst () (List.map (fun (x,y) -> y) serv_state.log); process_heartbeat msg; ()
    | "sendall" -> send_heartbeats (); ()
    | "vote_req" -> handle_vote_req msg oc; ()
    | "vote_res" -> handle_vote_res msg; ()
    | "appd_req" -> begin
                        print_endline "received app";
                        if serv_state.role = Candidate
                        then ignore (lose_election ());
                        ignore (handle_ae_req msg oc);
                        ()
                    end
    | "appd_res" -> handle_ae_res msg oc; ()
    | "find_leader" ->
        let res_id = if (serv_state.role = Leader) then serv_state.id
        else serv_state.leader_id in
        let res = "{\"type\": \"find_leader_res\", \"leader\": \""^res_id^"\"}" in
        ignore (send_msg res oc); ()
    | "find_leader_res" -> leader_ip := (msg |> member "leader" |> to_string)
    | "client" ->
        (* create the append_entries_rpc *)
        let new_entry = {
                value = msg |> member "value" |> to_int;
                entry_term = serv_state.curr_term;
                index = (get_p_log_idx ()) + 1;
            } in

        let pli = get_p_log_idx () in
        let plt = get_p_log_term () in

        let old_log = serv_state.log in
        let new_idx = (List.length old_log) + 1 in
        serv_state.log <- (new_idx,new_entry)::old_log;

        let output_channels_to_rpc =
            List.map (fun (id,(_,oc)) -> (oc, create_rpc msg id pli plt)) !channels in
        get_ae_response_from := (!get_ae_response_from @ output_channels_to_rpc); ()
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

let setup_connections () =
    List.iter (fun (_,(_,oc)) -> ignore (send_ip oc); ()) !channels;
    let chans = List.map (fun (ips, ic_ocs) -> ic_ocs) !channels in
    List.iter
    (fun (ic, oc) -> Lwt.on_failure (handle_connection ic oc ())
        (fun e -> Lwt_log.ign_error (Printexc.to_string e));) chans

(* [init_server ()] starts up this server as a follower and anticipates an
 * election. That is, this should ONLY be called as soon as the server begins
 * running (and after it has set up connections with all other servers) *)
let init_server () =
    change_heartbeat ();
    setup_connections ();
    serv_state.started <- true;
    init_follower ()

let accept_connection conn =
   print_endline "accepted";
    let fd, _ = conn in
    let ic = Lwt_io.of_fd Lwt_io.Input fd in
    let oc = Lwt_io.of_fd Lwt_io.Output fd in
    let otherl = !channels in
    let ip = "" in
    channels := ((ip, (ic, oc))::otherl);
    let iplistlen = List.length (serv_state.neighboring_ips) in
    if (List.length !channels)=iplistlen&&(not serv_state.started)&&serv_state.is_server
    then init_server ();
    (* accept the client's connections so need to remap channels *)
    if serv_state.started then setup_connections ();
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
    ignore (bind sock @@ ADDR_INET(listen_address, portnum));
    listen sock backlog;
    sock

let main_client address portnum =
    try
        let sockaddr = Lwt_unix.ADDR_INET(Unix.inet_addr_of_string address, portnum) in
        print_endline "main client";
        print_endline (string_of_int (List.length (serv_state.neighboring_ips)));
        let%lwt ic, oc = Lwt_io.open_connection sockaddr in
        let otherl = !channels in
             let ip = "" in
             channels := ((ip, (ic, oc))::otherl);
             let iplistlen = List.length (serv_state.neighboring_ips) in
             print_endline ("neighboring_ips: "^(string_of_int iplistlen));
             if (List.length !channels)=iplistlen && serv_state.is_server && (not serv_state.started)
             then (print_endline "connections good"; init_server ())
             else print_endline "not good";

        Lwt_log.info "added connection" >>= return
    with
        Failure _ -> Printf.printf "bad port number";
                                        exit 2 ;;

let establish_connections_to_others () =
    print_endline "establish";
    let ip_ports_list = serv_state.neighboring_ips in
    let rec get_connections lst =
        match lst with
        | [] -> ()
        | (ip_addr, portnum)::t ->
        begin
            ignore (main_client ip_addr portnum);
            get_connections t;
        end
    in get_connections ip_ports_list

let create_server sock =
    let rec serve () =
        Lwt_unix.accept sock >>= accept_connection >>= serve
    in serve

let rec st port_num =
    serv_state.id <- ((Unix.string_of_inet_addr (get_my_addr ())) ^ ":" ^ (string_of_int port_num));
    read_neighboring_ips port_num;
    establish_connections_to_others ();
    let sock = create_socket port_num () in
    let serve = create_server sock in
    Lwt_main.run @@ serve ();;

let _ = Random.self_init()

(* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
 *                                                                           *
 *                                                                           *
 * WEBSOCKET FOR A CLIENT IMPL                                               *
 *                                                                           *
 *                                                                           *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *)

(* [send_msg_from_client msg querying_leader] sends a message to the ip, and
 * also handles leader redirection.
 *)
let rec send_msg_from_client msg querying_leader =
    (* this condition is true if leader has not been found yet *)
    if (!leader_ip="") then
        match querying_leader with
        (* true if we are waiting for a response in order to wait to assign
         * the leader ip. *)
        | true ->  Lwt.on_termination (Lwt_unix.sleep 1.)
                        (fun () -> (send_msg_from_client msg true));
        (* otherwise, send an rpc to the first server to ask for the leader ip
         * and assign it.*)
        | false ->
            (* open the output channels *)
            let chans = List.map (fun (ips, ic_ocs) -> ic_ocs) !channels in
            List.iter
            (fun (ic, oc) -> Lwt.on_failure (handle_connection ic oc ())
            (fun e -> Lwt_log.ign_error (Printexc.to_string e));) chans;
            (* send the json requesting for the leader ip *)
            let find_ip_json = "{\"type\":\"find_leader\"}" in
            match List.nth_opt !channels 0 with
            | Some (ip, (ic, oc)) -> ignore (send_msg find_ip_json oc);
                                     send_msg_from_client msg true
            | None -> ()
    (* otherwise, send the new updated value to be entered to the leader *)
    else match (List.assoc_opt !leader_ip !channels) with
            | None -> ()
            | Some (ic, oc) ->
                let new_val_json = "{\"type\":\"client\",\"value\":"^msg^"}" in
                ignore (send_msg new_val_json oc); ()

(* [handler conn req body] is the handler for the websocket connections, in
 * sending and receiving messages from the web client.
 *)
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
  let uri = Cohttp.Request.uri req in
  (* websocket will connect to this url and will listen on this uri *)
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
                (* send the message from the client to commit to rest of server
                 *)
                send_msg_from_client f.content false;
                Printf.eprintf "[RECV] %s\n%!" f.content
    );
    >>= fun (resp, body, frames_out_fn) ->
    (* send a message to the client *)
    let _ =
            let rec go () =
                Lwt_io.eprintf "[SEND] %s\n%!" !res_client_msg
                >>= fun () ->
                Lwt.wrap1 frames_out_fn @@
                    Some (Frame.create ~content:!res_client_msg ())
                >>= fun () ->
                Lwt_unix.sleep 1.
                >>= go
        in
        go ()
    in
    Lwt.return (resp, (body :> Cohttp_lwt_body.t))
  | _ ->
    Lwt_io.eprintf "[PATH] Catch-all\n%!"
    >>= fun () ->
    Cohttp_lwt_unix.Server.respond_string
        ~status:`Not_found
        ~body:(Sexplib.Sexp.to_string_hum (Cohttp.Request.sexp_of_t req))
        ()

(* [start_websocket host port_num] begins a websocket on the given host and port
 * The purpose is for the web client to connect to this to interface with the
 * other server. This will communicate with the rest of the server cluster
 * on port (port_num + 1). Have the web client connect on ip:port_num
 *)
let start_websocket host port_num () =
  (* initialize the client server to connect to all the servers on the list *)
  serv_state.is_server <- false;
  read_neighboring_ips port_num;
  establish_connections_to_others ();
  let sock = create_socket (port_num+1) () in
  let serve = create_server sock in

  (* begin the websocket *)
  let conn_closed (ch,_) =
    Printf.eprintf "[SERV] connection %s closed\n%!"
      (Sexplib.Sexp.to_string_hum (Conduit_lwt_unix.sexp_of_flow ch))
  in
  Lwt_io.eprintf "[SERV] Listening for HTTP on port_num %d\n%!" port_num >>= fun () ->
  ignore (Cohttp_lwt_unix.Server.create
    ~mode:(`TCP (`Port port_num))
    (Cohttp_lwt_unix.Server.make ~callback:handler ~conn_closed ()));
  (* run the server *)
  Lwt_main.run @@ serve ()

(* [start_client] begins the client server, by default, localhost:3001 *)
let start_client () =
    start_websocket (Unix.string_of_inet_addr (get_my_addr ())) 3001 ()