
(* term: candidate’s term
 * candidate_id: candidate requesting vote
 * last_log_index: index of candidate’s last log entry
 * last_log_term: term of candidate’s last log entry
 *)
module type VoteReq = sig
  type vote_req = {
    term : int;
    candidate_id : int;
    last_log_index : int;
    last_log_term : int
  }
end

(* current_term: currentTerm, for candidate to update itself
 * vote_granted: true means candidate received vote
 *)
module type VoteRes = sig
  type vote_res = {
    current_term : int;
    vote_granted : bool
  }
end