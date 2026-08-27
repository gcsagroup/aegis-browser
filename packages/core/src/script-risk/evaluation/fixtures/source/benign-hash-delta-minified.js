// Synthetic benign local checksum control. Parsed as text; never executed.
export function h(a){let s=1;for(const v of a.slice(0,128))s=(Math.imul(s^v,2654435761)^(s<<3)^(s>>>5)^(s<<7)^(s>>>11))>>>0;return s}
