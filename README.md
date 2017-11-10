# RaftML

## Installation

Install [ocaml-websocket](https://github.com/vbmithr/ocaml-websocket) by following instructions and also running `opam install async_ssl` when an error happens.

## Weekly workflow
Mon Wed meetings after 3110 Discussion
Fri | Sat | Sun meetings as necessary

## Implementation Timeline (in order of priority)
1. Pure sockets proof of concept (independent of Raft modules)
2. Basic server-server communication w/ pure sockets (using Raft modules)
3. Leader election
4. Log replication
5. Client side impl with websockets to communciate to leader lel idk

Dependencies:
ocaml-websocket
