(* module representing an RPC (remote procedure call), which is how servers
 * communicate between each other
 * RequestVote and AppendEntries RPCs are required by the consensus algorithm
 *
 * InstallSnapshot RPC is an additional feature of the algorithm defined in 
 * log compaction (section 7) of the whitepaper *)

(* defines the RPC message types allowed *)
type message = RequestVote | AppendEntries

module type RPC = sig
	type t = message
	type args
	type results
end

module RequestVoteRPC : RPC = struct
	type t = RequestVote
	type args = {
		candidateTerm 	: int;
		candidateID		: int;
		lastLogIdx		: int;
		lastLogTerm		: int
	}

	type results = {
		term 			: int;
		voteGranted	 	: bool
	}
end

module AppendEntriesRPC : RPC = struct
	type t = AppendEntries
	type args = {
		leaderTerm 		: int;
		leaderID		: int;
		prevLogIdx		: int;
		prevLogTerm		: int;
		entries 		: entry list;
		leaderCommit 	: int
	}

	type results = {
		term 			: int;
		success			: bool
	}
end

