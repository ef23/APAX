(* specifications for a Log module that represents a data structure for
 * storing and manipulating log entries *)

(* represents a log entry to be stored in the log.
 * each entry contains all the necessary information for determining
 * whether two entrys can be matched/compared. This includes, but is not
 * limited to:
 * -value for the state machine
 * -term when the entry was received by the leader
 * -entry index indicating that it is the ith entry in the log *)
type entry = {
  value: int;
  entryTerm : int;
  index : int;
}

(* abstract Log module signature; a Log must be able to manipulate
 * and compare entries. *)
module type Log = sig
	type log

	(* [empty] returns an empty log *)
	val empty: log

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
(*
	[MergeLogs (L1) (L2)] takes in two Logs and merges them
	module MergeLogs (L1 : Log) (L2 : Log) = sig
	end *)

