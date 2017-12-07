type vote_req = {
  term : int;
  candidate_id : string;
  last_log_index : int;
  last_log_term : int
}

type vote_res = {
  curr_term : int;
  vote_granted : bool
}
