First, https://github.com/vbmithr/ocaml-websocket must be cloned and built according to its `README`. This may require a bunch of dependencies during the build process. This is the only third party dependency we have (aside from `Lwt` and `Yojson`).

Next, a simple make compile should do in order to compile the project.

Next, navigate to client/ and run `npm install` in order to install the npm dependencies required for the web client frontend. This of course requires `npm` to be installed. Then, run `npm start`.

After this, we ran our servers and client server in `utop`. We supplied the ips to the server (along with ports), in the `ips.txt`. We were able to simulate multiple servers by running it on multiple ports (see the `ips.txt` file). You can add any number of servers to this, as long as you initialize with all the servers first.

The following ports are reserved: 3000, 3001, 3002. This is for the client server (which interfaces with the web frontend client via websocket on 3001, the node server for React on 3000, and the socket for the client server on port 3002).

Next, for each `utop` instance for each server, run `st ####` where `####` is the port number that corresponds to the servers' port numbers in `ips.txt`. It will look like each instance is hanging until every server is started and the client is connected.

Next, open one last `utop` instance to run the client server - run `start_client ()`. The leader should soon be elected.

Then lastly, go to the ReactJS frontend on localhost:3000 in your favorite browser (if `npm start` did not already open it for you) that supports JavaScript, then enter localhost:3001 (to connect to the client server) into the text box, and you should be able to send new log values (integers) to the server.

Logs of the servers should be in the `utop` console, although the followers are probably being spammed by heartbeats.

Example: after installing all dependencies, then open 4 `utop` instances, and one more terminal to npm start in.

Let's say you want to simulate 3 servers - running on ports 9000, 9001, and 9002.

In 3 `utop` instances, run `st 9000`, `st 9001`, and `st 9002`.
In the last `utop` instance, run `start_client ()`
Next, run `npm start` in the last terminal after navigating to cd client/
Open localhost:3000 in the browser, connect to localhost:3001 and then you can update values with int values.

You can stop servers by exiting the terminal window.
