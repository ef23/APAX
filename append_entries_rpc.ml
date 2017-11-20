open Log

type append_entries_req = {
  term : int;
  leader_id : int;
  prev_log_index : int;
  prev_log_term : int;
  entries : entry list;
  leader_commit : int
}


type append_entries_res = {
  current_term : int;
  success : bool
}

