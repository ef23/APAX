(* specifications for a Log module that represents a data structure for 
 * storing and manipulating log entries *)

(* represents a log entry to be stored in the log.
 * each entry contains all the necessary information for determining
 * whether two entrys can be matched/compared *)
type entry

(* abstract Log module signature; a Log must be able to manipulate
 * and compare entries. *)
module type Log = sig
	type log = entry list

	val add : log -> entry -> log
	val remove : log -> entry -> log

	(* compare and match may end up being two different necessary functions *)
	val compare : entry -> entry -> bool
	val match : entry -> entry -> bool
end

(* [MergeLogs (L1) (L2)] takes in two Logs and merges them *)
module MergeLogs = functor (L1 : Log) (L2 : Log) -> struct
end

