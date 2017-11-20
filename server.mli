open Request_vote_rpc
open Append_entries_rpc
(* Represents a server which manages
	its own state. Thus, the server
	defines the set of valid functions
	on a state, and stores the server's
	own information that cannot be
	transformed.
 *)

(* hi andrei ¯\_(ツ)_/¯*)

(* Follower, Candidate, Leader *)
type role
(* = | Follower | Candidate | Leader *)

(* Unique ID of this node (server) *)
type id
(* = int *)

(* State representation *)
type state

type ip_address_str = string

(* Gets the IP of this server *)
val get_my_addr: unit -> Unix.inet_addr

(* Returns a string upon receiving a message *)
val handle_message: string -> string

(* Initialize state with list of other IPs in the consensus system *)
val init_state : string list -> state

(* return a state with a new randomized heartbeat when a node transitions from a
 * candidate to a follower *)
val change_heartbeat: unit -> unit

(* [transition st r] returns a new state
 * st' where st'.role = r
 * and  *)
val transition : state -> role -> state

(* [req_append_entries str] sends an appendEntries call to another server 
 * [str] is the message we want to send bc we were REQ u 
 *)
val req_append_entries : AppendEntriesReq.append_entries_req -> ip_address_str -> unit

(* [res_append_entries str] sends an appendEntries call to another server 
 * [str] is the message we want to send
 *)
val res_append_entries : AppendEntriesRes.append_entries_res -> ip_address_str -> unit

(* [req_request_vote str] sends an requestVote call 
 * [str] is the message we want to send
 *)
val req_request_vote : VoteReq.vote_req -> ip_address_str -> unit

(* [res_request_vote str] sends an requestVote call 
 * [str] is the message we want to send
 *)
val res_request_vote : VoteReq.vote_req -> ip_address_str -> unit

(* Client-server interaction: Client has a list of the server ips they can
 * connect to; can communicate with any server and the server will send the data
 * (without processing it) to the leader to process.
 * TODO Websocket and Redirection *)

(* Definition of election timeout: a randomized time set for a node at the start
 * and when it transitions from candidate => follower.
 * This is BOTH the period of time a node spends as a follower before starting
 * an election as a candidate (during which it can receive heartbeats from the
 * leader) AND the duration of election. Basically changed every term. *)
