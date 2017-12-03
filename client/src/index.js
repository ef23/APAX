import React from 'react';
import ReactDOM from 'react-dom';
import './index.css';

class App extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      curr_val: "",
      box_text: ""
    };
    this.updateText = this.updateText.bind(this);
    this.sendUpdate = this.sendUpdate.bind(this);
  }

  componentWillMount() {
    // call for the most recent value i guess
  }

  updateText(e) {
    this.setState({
      box_text: e.target.value
    });
  }

  sendUpdate(){
    console.log(this.state.box_text);
    // send value via websocket
    this.setState({
      box_text: ""
    });
  }

  render () {
    return(
      <div className = "text-center">
        <h1> APAX </h1>
        <h2> The current value is: {this.state.curr_val} </h2>
        <input type="text" value={this.state.box_text} onChange={this.updateText.bind(this)}/>
        <button onClick={this.sendUpdate.bind(this)}> Update </button>
      </div>
    );
  }
}

ReactDOM.render(<App />, document.getElementById('root'));
