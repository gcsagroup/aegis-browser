// Synthetic benign local checksum control. Parsed as text; never executed.
export function checksum(values, mode) {
  let state = 2166136261;
  switch (mode) {
    case "compact":
      for (const value of values.slice(0, 128)) {
        state = Math.imul(state ^ value, 16777619);
        state = (state ^ (state << 5) ^ (state >>> 7) ^ (state << 9)) >>> 0;
      }
      break;
    default:
      state = 0;
  }
  return state;
}
