(* Represents a request made by a candidate node to gather votes in an
 * election and the response.
 *)

(* term: candidate’s term
 * candidate_id: candidate requesting vote
 * last_log_index: index of candidate’s last log entry
 * last_log_term: term of candidate’s last log entry
 *)
type vote_req = {
  term : int;
  candidate_id : string;
  last_log_index : int;
  last_log_term : int
}

(* current_term: currentTerm, for candidate to update itself
 * vote_granted: true means candidate received vote
 *)
type vote_res = {
  current_term : int;
  vote_granted : bool
}
