First, https://github.com/vbmithr/ocaml-websocket must be cloned and built. This may require a bunch of dependencies during the build process. This is the only third party dependency we have (aside from Lwt). 

Next, a simple make compile should do in order to compile the project. 

Next, navigate to client/ and run npm install in order to install the npm dependencies required for the web client frontend. 

After this, we ran our servers and client server in utop. We supplied the ips to the server (along with ports), in the ips.txt. We were able to simulate multiple servers by running it on multiple ports (see the ips.txt file). You can add any number of servers to this, as long as you initialize with all the servers first. 

The following ports are reserved: 3000, 3001, 3002. This is for the client server (which interfaces with the web frontend client via websocket on 3001, the node server for React on 3000, and the socket for the client server on port 3002). 

Next, for each utop instance for each server, run st #### where #### is the port number that corresponds to the servers' port numbers in ips.txt. 

Next, open one last utop instance to run the client server - run start_client () 

Then lastly, go to the ReactJS frontend on localhost:3000 in your favorite browser, then enter localhost:3001 (to connect to the client server), and you should be able to send new log values to the server. 

Logs of the servers should be in the utop console, although the followers are probably being spammed by heartbeats. 