open Log

type append_entries_req = {
  ap_term : int;
  leader_id : string;
  prev_log_index : int;
  prev_log_term : int;
  entries : entry list;
  leader_commit : int
}

type append_entries_res = {
  curr_term : int;
  success : bool
}
