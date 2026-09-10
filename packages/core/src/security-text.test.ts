import { describe, expect, it } from "vitest";
import { normalizeSecurityText } from "./security-text.js";
import { assessPhishing } from "./phish/detector.js";
import { assessWithModel, createLightweightPhishModel } from "./phish/lightweight-model.js";
import { buildSummarizePrompt } from "./privacy/orchestrator.js";

describe("隐形 Unicode 走私防护", () => {
  it("逐个清理完整 Tags 区块，不解码隐藏指令", () => {
    for (let point = 0xe0000; point <= 0xe007f; point += 1) {
      expect(normalizeSecurityText(`ver${String.fromCodePoint(point)}ify`))
        .toEqual({ text: "verify", removedHiddenCodepoints: 1 });
    }
    expect(normalizeSecurityText("\u{e0072}\u{e0075}\u{e006e}").text).toBe("");
  });

  it("精确保留三个地区旗帜，伪造旗帜不能放行任意隐藏消息", () => {
    for (const code of ["gbeng", "gbsct", "gbwls"]) {
      const flag = "\u{1f3f4}" +
        [...code].map((char) => String.fromCodePoint(0xe0000 + char.charCodeAt(0))).join("") +
        "\u{e007f}";
      expect(normalizeSecurityText(flag)).toEqual({ text: flag, removedHiddenCodepoints: 0 });
      expect(normalizeSecurityText(flag + "\u{e0078}").text).toBe(flag);
    }
    expect(normalizeSecurityText("\u{1f3f4}\u{e0072}\u{e0075}\u{e006e}\u{e007f}").text)
      .toBe("\u{1f3f4}");
  });

  it("保留多语言、连字和普通 emoji，清理明确的无显示分隔符", () => {
    const text = "中文 café العربية می\u200cروم 👩‍💻 ❤️";
    expect(normalizeSecurityText(text).text).toBe(text);
    expect(normalizeSecurityText("pass\u200bword\u2060\u00ad\ufeff").text).toBe("password");
    expect(normalizeSecurityText("verify\u00a0your\u202faccount").text).toBe("verify your account");
  });

  it("加盐不能降低规则或本地模型的检测结果", async () => {
    const original = {
      url: "http://example.test/", title: "PayPal",
      textSample: "verify your account", passwordFields: 1, forms: 1,
    };
    const salted = { ...original,
      title: "Pay\u{e0020}Pal", textSample: "ver\u{e0020}ify your acc\u200bount",
    };
    expect(assessPhishing(original).shouldBlock).toBe(true);
    expect(assessPhishing(salted).score).toBe(assessPhishing(original).score);
    const model = createLightweightPhishModel();
    expect(await model.score(salted)).toBe(await model.score(original));
    let received = "";
    await assessWithModel(salted, [], { async score(snapshot) {
      received = snapshot.textSample; return null;
    } });
    expect(received).toBe(original.textSample);
    const benign = assessPhishing({
      url: "https://example.test/", title: "研究", textSample: "普通\u{e0020}文本",
    });
    expect(benign.shouldBlock).toBe(false);
    expect(benign.score).toBe(0);
  });

  it("先归一化再脱敏，不能把还原的密钥重新送进模型", () => {
    const prompt = buildSummarizePrompt({ locale: "zh-CN", snapshot: {
      url: "https://example.test/", title: "文\u{e0020}章",
      textSample: "Be\u{e0020}arer abcdefghijklmnop. Visible text. \u{e0072}\u{e0075}\u{e006e}",
    } });
    expect(prompt.user).toContain("文章");
    expect(prompt.user).toContain("Visible text.");
    expect(prompt.user).not.toContain("abcdefghijklmnop");
    expect(prompt.user).not.toMatch(/[\u{e0000}-\u{e007f}]/u);
  });
});
