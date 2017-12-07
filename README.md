# MS 2: APAX
Andy Zhang (jz359), Eric Feng (evf23), Maria Sam (ms2878), Janice Chan (jc2729)

## Running

See [README.txt](./README.txt)

## Introduction
A core problem in distributed computing is maintaining a consensus amongst distributed
servers. There are many motivations for this, such as reliable storage and maintenance
of alterable states (which can be interpreted as data or machine states), and the
applications for such a distributed system span several industries.

## System Description
We are implementing Raft, which is a distributed consensus algorithm for managing a replicated
log and state across distributed systems. Specifically, we are introducing the APAX
system, which is a set of distributed server clusters and a multi-client interface that
allows multiple users to store, update, and retrieve data in a reliable way. Some key
features include:

- Socket networking for distributed servers and clients
-  User-friendly interface for clients to connect
- Randomized timing for leader election and stability
- Log replication for predictable, safe state machines
- Leader election for when the current leader fails
- Dynamic leader redirection for client-side access

## System Design
System Design:
The core of the system lies in the distributed servers and the consensus algorithm that ensures uniform agreement on the data state. The main pieces that constitute this server-side architecture include the server, log, append entries request and response, and request vote request and response modules, with their general purposes discussed below.

- `server`: Represents a server that maintains a state and has a role (Leader|Follower|Candidate) which are modified as part of the consensus algorithm. Roles are decided based on randomized times (for Follower|Candidate) and elections (for Leader) based on the specifications of the Raft algorithm.

- `log`: Represents a log of client commands and server-server interactions that each server and its state maintains. A log is essentially a list of entry types that contain information about the server necessary for log replication and leader selection to take place in the server cluster.

- `append_entries_rpc`: Represents a call from a Leader server to its Follower servers to append an entry (or multiple entries) to its log, and the subsequent reply from the Follower to the Leader.

- `request_vote_rpc`: Represents a call from a Candidate server to all Follower servers during an election term. Contains the necessary information for voters to either accept or reject the request.

Communication between servers and clients is established using sockets. They will communicate via the TCP protocol, and we will treat the client as its own server. Each server in the distributed system will have its own socket to communicate with other servers, and the same socket can be accessed by the client to communicate with the server.

## Module Design

The modules described in the system design have interfaces that are attached with this design document submission as part of the source code.

## Data
Our system stores an integer on all of its servers, and allows the client to retrieve the integer from the servers, as well set the integer to be stored. Communication from the client and/or server to any given server (and vice versa) is handled using the Lwt library from OCaml, and the data transmitted is in the form of RPCs (remote procedure calls) which are defined as modules in our system.

The RPCs are represented by records; there are four types of RPCs, for vote requests, vote responses, append entries requests, and append entries responses. These are sent in JSON format between servers because that allows us to stringify OCaml data structures like records and then parse them using Yojson on the receiving end.

To represent the state of the servers, we use a record with mutable fields. 
This keeps track of the server role, the id of the server, leader id, the current term, the server that it voted for, the log of its entries, the commit index, its heartbeat timer value, the next index list of the log, the last applied entry, the match index, and the neighboring ip addresses. 

We will using association lists to keep track of entries in a log, where entries are represented by records containing the command (store, retrieve) passed to the system from the client, the term when the entry was received by the leader of the system, and the index of the entry in the entries list.

## External Dependencies

We depend on the Lwt library for our networking infrastructure, as well as Node.js for the client-side application (this requires the installation of the Node Package Manager aka npm).

- Lwt
- Yojson
- ocaml-websocket
- ohttp (should come with ocaml-websocket)
- npm (Node.js, ReactJS)

## Testing Plan

The two major components of the Raft algorithm (and thus our project) are Leader Election and Log Replication. Both rely on the underlying networking established with Lwt, so our testing plan is reflected accordingly.

- Server-server communication via heartbeats. We test this by setting up two servers that establish socket connections with each other, and communicate via the input/output channels provided by the socket connection. As a proof of concept, we simply send over "heartbeats", which are henceforth known as AppendEntries requests (formatted as a JSON-parsable string) with empty "entries" parameter.

- Leader Election. Having confirmed the ability to send information from one server to another, we test Leader Election by initializing 3 servers (as Followers, per the algorithm) with randomized timeouts and observe that one of them is elected and begins sending heartbeats in order to establish its authority amongst the un-elected servers. We also test the ability for our servers to re-elect themselves when the Leader stops sending heartbeats (i.e. in the event of failure) by stopping the Leader server and observing as the remaining Follower servers timeout and start a new election and find a new Leader.

- Log Replication. With Leader Election working, we now proceed to test Log Replication, which ensures that the servers maintain a consensus. A client is set up as a server that can send messages to the Leader (which are formatted as JSON-parsable strings and processed by the Leader accordingly) with the goal of updating the value of the server cluster. Once the Leader sends out requests and processes replies from the Followers according to the algorithm, it will notify the client of the updated value, which will indicate that log replication was sustained correctly under normal circumstances. We then stop the Leader server from running, allow the election of a new Leader, and observe that the value still has not changed within the cluster because the original Leader's log was replicated successfully on all Followers. This completes our check for correctness in our log replication implementation.

## Division of labor

The core features (as stated in the system description) are listed, along with the names of the people who predominantly worked on them.

- Socket networking for distributed servers and clients: Maria, Janice, Eric
- User-friendly interface for clients to connect and dynamic leader redirection for client-side access: Eric
- Randomized timing for leader election and stability: Andy, Eric, Maria, Janice
- Log replication for predictable, safe state machines: Andy, Janice, Maria
- Leader election for when the current leader fails: Andy, Eric, Maria, Janice


Hours were evenly distributed due to allocation of work hours in which everyone would be available to meet. They are distributed as follows:

- Andy: 60 hours
- Eric: 60 hours
- Maria: 60 hours
- Janice: 60 hours

## Weekly workflow
Mon Wed meetings after 3110 Discussion
Fri | Sat | Sun meetings as necessary

## Implementation Timeline (in order of priority)
1. Pure sockets proof of concept (independent of Raft modules)
2. Basic server-server communication w/ pure sockets (using Raft modules)
3. Leader election
4. Log replication
5. Client side impl to communciate to leader



