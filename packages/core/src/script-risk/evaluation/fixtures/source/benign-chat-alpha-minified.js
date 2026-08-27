// Synthetic benign control. Parsed as text by the evaluator; never executed.
export function c(r){const w=new Worker("/emoji-worker.js"),s=new WebSocket("wss://chat-alpha.example.test/socket");s.send(JSON.stringify({type:"join",room:r}));return{w,s}}
