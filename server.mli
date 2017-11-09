(* Represents a server which manages
	its own state. Thus, the server
	defines the set of valid functions
	on a state, and stores the server's
	own information that cannot be
	transformed.
 *)

(* Follower, Candidate, Leader *)
type role = | Follower | Candidate | Leader

(* Unique ID of this node (server) *)
type id = int

type entry

(* State representation *)
type state = {
	role : role;
	term : int;
	votedfor : int;
	log : entry list;
	commit_index : int;
	last_applied : int;
	next_index : int;
	match_index : int;
	neighboring_ips : string list
}

(* Initialize state with list of other IPs in the consensus system *)
val init_state : string list -> state

(* [transition st r] returns a new state
 * st' where st'.role = r 
 * and  *)
val transition : state -> role -> state

(* Client-server interaction: Client has a list of the server ips they can 
 * connect to; can communicate with any server and the server will send the data
 * (without processing it) to the leader to process. 
 * TODO Websocket and Redirection *)
 
(* Definition of election timeout: a randomized time set for a node at the start
 * and when it transitions from candidate => follower.
 * This is BOTH the period of time a node spends as a follower before starting
 * an election as a candidate (during which it can receive heartbeats from the 
 * leader) AND the duration of election. Basically changed every term. *)
