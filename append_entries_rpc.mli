open Log
(* Represents a call made by leader to replicate log entries, and is also used
 * as heartbeat to ensure that leader is still alive and the response.
 *)

(* term: leader's term
 * leader_id: id of leader so follower can redirect clients
 * prev_log_index: index of log entry immediately preceding new ones
 * entries: list of entries of type 'a to store in log
 * leader_commit: leader's commit index
 *)
type append_entries_req = {
  ap_term : int;
  leader_id : string;
  prev_log_index : int;
  prev_log_term : int;
  entries : entry list;
  leader_commit : int
}


(* current_term: for leader to update its current term
 * success: if the follower contained entry matching prevLogIndex and
 * prevLogTerm
 *)
type append_entries_res = {
  current_term : int;
  success : bool
}
