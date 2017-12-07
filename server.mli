open Request_vote_rpc
open Append_entries_rpc
open Lwt
(* Represents a server which manages
	its own state. Thus, the server
	defines the set of valid functions
	on a state, and stores the server's
	own information that cannot be
	transformed.
 *)

(* Follower, Candidate, Leader *)
type role
(* = | Follower | Candidate | Leader *)

(* State representation *)
type state

(* Gets the IP of this server *)
val get_my_addr: unit -> Unix.inet_addr

(* Returns a string upon receiving a message *)
val handle_message: string -> Lwt_io.output_channel -> unit

(* return a state with a new randomized heartbeat when a node transitions from a
 * candidate to a follower *)
val change_heartbeat: unit -> unit

(* [req_append_entries str] sends an appendEntries call to another server
 * [str] is the message we want to send
 *)
val req_append_entries : append_entries_req -> string -> Lwt_io.output_channel -> unit Lwt.t

(* [res_append_entries str] sends an appendEntries call to another server
 * [str] is the message we want to send
 *)
val res_append_entries : append_entries_res -> Lwt_io.output_channel -> unit Lwt.t

(* [req_request_vote str] sends an requestVote call
 * [str] is the message we want to send
 *)
val req_request_vote : vote_req -> Lwt_io.output_channel -> unit Lwt.t

(* [res_request_vote str] sends an requestVote call
 * [str] is the message we want to send
 *)
val res_request_vote : Yojson.Basic.json -> Lwt_io.output_channel -> unit Lwt.t
