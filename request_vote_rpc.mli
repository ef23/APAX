(* Represents a request made by a candidate node to gather votes in an 
 * election and the response.
 *)

(* term: candidate’s term
 * candidate_id: candidate requesting vote
 * last_log_index: index of candidate’s last log entry
 * last_log_term: term of candidate’s last log entry
 *)
module VoteRequest = sig
  type vote_request = {
    term : int;
    candidate_id : int;
    last_log_index : int;
    last_log_term : int
  }
end

(* current_term: currentTerm, for candidate to update itself
 * vote_granted: true means candidate received vote
 *)
module VoteResponse : sig
  type vote_response = {
    current_term : int;
    vote_granted : bool
  }
end