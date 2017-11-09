(* Represents a call made by leader to replicate log entries, and is also used 
 * as heartbeat to ensure that leader is still alive and the response.
 *)

(* term: leader's term
 * leader_id: id of leader so follower can redirect clients
 * prev_log_index: index of log entry immediately preceding new ones
 * entries: list of entries of type 'a to store in log
 * leader_commit: leader's commit index
 *)
module AppendEntriesRequest : sig
  type 'a append_entries_request = {
    term : int;
    leader_id : int;
    prev_log_index : int;
    prev_log_term : int;
    entries : 'a list;
    leader_commit : int
  } 
end


(* current_term: for leader to update its current term
 * success: if the follower contained entry matching prevLogIndex and 
 * prevLogTerm
 *)
module AppendEntriesResponse : sig
  type append_entries_response = {
    current_term : int;
    success : bool
  }   
end
