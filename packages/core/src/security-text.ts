// 与 Chromium security_text.cc 保持一致；只处理检测/模型副本，不改写操作地址。
const SUBDIVISION_FLAGS = [
  "\u{1f3f4}\u{e0067}\u{e0062}\u{e0065}\u{e006e}\u{e0067}\u{e007f}",
  "\u{1f3f4}\u{e0067}\u{e0062}\u{e0073}\u{e0063}\u{e0074}\u{e007f}",
  "\u{1f3f4}\u{e0067}\u{e0062}\u{e0077}\u{e006c}\u{e0073}\u{e007f}",
];

export function normalizeSecurityText(input: string): {
  text: string;
  removedHiddenCodepoints: number;
} {
  const output: string[] = [];
  let removedHiddenCodepoints = 0;
  for (let index = 0; index < input.length;) {
    const flag = SUBDIVISION_FLAGS.find((value) => input.startsWith(value, index));
    if (flag) {
      output.push(flag);
      index += flag.length;
      continue;
    }
    const codepoint = input.codePointAt(index)!;
    index += codepoint > 0xffff ? 2 : 1;
    if ((codepoint >= 0xe0000 && codepoint <= 0xe007f) ||
        [0x00ad, 0x200b, 0x2060, 0xfeff].includes(codepoint)) {
      removedHiddenCodepoints += 1;
      continue;
    }
    output.push(codepoint === 0x00a0 || codepoint === 0x202f
      ? " " : String.fromCodePoint(codepoint));
  }
  return { text: output.join(""), removedHiddenCodepoints };
}
