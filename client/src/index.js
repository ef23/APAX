import React from 'react';
import ReactDOM from 'react-dom';
import 'ws';
import './index.css';

class App extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      curr_val: "",
      box_text: "",
      ip_address: "",
      ip_page_msg: "",
      ws: "",
      ws_page_msg: "",
    };
    this.updateText = this.updateText.bind(this);
    this.sendUpdate = this.sendUpdate.bind(this);
    this.setIPAddress = this.setIPAddress.bind(this);
    this.openWebsocket = this.openWebsocket.bind(this);
  }

  failWebsocket() {
    this.setState({
        ip_address: "",
        box_text: "",
        ip_page_msg: "Invalid IP! Either not a leader or the leader went down."
      });
  }

  openWebsocket(ip) {
    let wsURL = 'ws://' + ip + '/';
    try {
      this.ws = new WebSocket(wsURL);
    } catch (e) {
      this.failWebsocket();
    }
    this.ws.onclose = (x) => {
      this.failWebsocket();
    }
    this.ws.onerror = (x) => {
      this.failWebsocket();
    }
    this.ws.onmessage = (x) => {
      console.log(x.data);
      this.setState({
        curr_val: x.data,
      });
    }
  }

  updateText(e) {
    this.setState({
      box_text: e.target.value
    });
  }

  setIPAddress() {
    let ip = this.state.box_text;
    this.setState({
      ip_address: ip,
      box_text: "",
      ip_page_msg: ""
    });
    this.openWebsocket(ip);
  }

  sendUpdate(){
    // send value via websocket
    this.setState({
      box_text: ""
    });
    try {
      if ((typeof parseInt(this.state.box_text))==="number") {
        this.ws.send(this.state.box_text);
        this.setState({
          ws_page_msg: "Sent!"
        });
      } else {
        this.setState({
          ws_page_msg: "Error with sending message! Make sure it is an integer"
        });
      }
    } catch(e) {
      this.setState({
        ws_page_msg: "Error with sending message! Make sure it is an integer"
      });
    }
  }

  render () {
    let client = (
      <div className = "text-center">
        <h1> APAX </h1>
        <h2> The current value is: {this.state.curr_val} </h2>
        <p> {this.state.ws_page_msg} </p>
        <span>
          <input type="text" value={this.state.box_text} onChange={this.updateText.bind(this)}/>
          <button onClick={this.sendUpdate.bind(this)}> Update </button>
         </span>
      </div>);
    let ip_address_input = (
      <div className = "text-center">
        <h1> APAX </h1>
        <h2> Please input the leader's IP address and port: </h2>
        <p> {this.state.ip_page_msg} </p>
        <input type="text" value={this.state.box_text} onChange={this.updateText.bind(this)}/>
        <button onClick={this.setIPAddress.bind(this)}> Set IP </button>
      </div>);

    return this.state.ip_address.length > 0 ? client : ip_address_input
  }
}

ReactDOM.render(<App />, document.getElementById('root'));
