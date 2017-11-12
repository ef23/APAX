# RaftML

## Installation


## Weekly workflow
Mon Wed meetings after 3110 Discussion
Fri | Sat | Sun meetings as necessary

## Implementation Timeline (in order of priority)
1. Pure sockets proof of concept (independent of Raft modules)
2. Basic server-server communication w/ pure sockets (using Raft modules)
3. Leader election
4. Log replication
5. Client side impl to communciate to leader

## Usage

### Server
To start a server, go to utop:
```
# #use "serv_up.ml";
# go_uppercase_service [port];;
```
To kill the server, run the following in terminal:
```
lsof -i:[port]
kill [pid]
```

### Client
To test the server, go to terminal:
`telnet [ip_address] [port]`

To exit from the client side, go to terminal:
`control ]`
