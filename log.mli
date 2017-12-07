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
  value : int;
  entry_term : int;
  index : int;
}

