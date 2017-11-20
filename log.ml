type entry = {
  command : string;
  entryTerm : int;
  index : int;
}

(* abstract Log module signature; a Log must be able to manipulate
 * and compare entries. *)
module type Log = sig
  type log

  (* [add l e] returns a log l' containing e and all of the items in l *)
  val add : log -> entry -> log

  (* [remove l e] returns a log l' containing all of the items in l except
   * e *)
  val remove : log -> entry -> log

  (* [match_log e1 e2] returns -1 if e1 is a more recent entry
   * than e2; 1 if e2 is more recent than e1; 0 if they are
   * the same entry *)
  val match_log : entry -> entry -> int

  (* [compare e1 e2] returns true if e1 and e2 are the same entries,
   * false otherwise *)
  val compare : entry -> entry -> bool
end

