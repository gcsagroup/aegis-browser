// Synthetic benign control. Parsed as text by the evaluator; never executed.
export function connectChat(room) {
  const socket = new WebSocket("wss://chat-alpha.example.test/socket");
  socket.send(JSON.stringify({ type: "join", room }));
  return socket;
}
