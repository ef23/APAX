# RaftML

## Installation

Install [ocaml-websocket](https://github.com/vbmithr/ocaml-websocket) by following instructions and also running `opam install async_ssl` when an error happens.

## Weekly workflow
Mon Wed meetings after 3110 Discussion
Fri | Sat | Sun meetings as necessary

## Implementation Timeline (in order of priority)
~~1. Websocket proof of concept (independent of Raft modules)~~
+ Verified with ocaml-websocket/test. Still need to confirm ability to have multiple connections for a single websocket.

2. Basic server-server communication w/ websockets (using Raft modules) and client-server communication
3. Leader election
4. Log replication

Dependencies:

ocaml-websocket
