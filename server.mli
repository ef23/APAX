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
}

(* [transition st r] returns a new state
 * st' where st'.role = r 
 * and  *)
val transition : state -> role -> state

(* TODO defined more functions on state *)