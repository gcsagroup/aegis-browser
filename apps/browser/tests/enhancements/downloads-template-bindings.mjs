import assert from 'node:assert/strict';
import {JSDOM} from 'jsdom';

// Unit contract for Lit's host receiver. Native15 owns the separate real Lit proof.
export function downloadBindings(ts, source) {
  const tree = ts.createSourceFile('downloads.html.ts', source, ts.ScriptTarget.Latest, true);
  assert.equal(tree.parseDiagnostics.length, 0, 'template must parse');
  const bindings = [];
  // Keep interpolations inert while the existing HTML parser identifies complete
  // attributes. Neither data-id nor id= text inside another value is a real ID.
  let markerPrefix = '__aegis_template_expression_';
  while (source.includes(markerPrefix)) markerPrefix += '_';
  function visit(node) {
    if (ts.isTemplateExpression(node)) {
      let previous = node.head.text;
      let html = previous;
      const expressions = [], events = [];
      for (const [index, span] of node.templateSpans.entries()) {
        const marker = `${markerPrefix}${node.pos}_${index}__`;
        const ref = span.expression;
        expressions.push([marker, '${' + ref.getText(tree) + '}']);
        html += marker + span.literal.text;
        // Lit permits quoted and unquoted values, and any event name. Count
        // extra event types too; the exact mapping below decides what is allowed.
        const event = /(?:^|[\t\n\f\r ])@([^\t\n\f\r "'<>/=]+)[\t\n\f\r ]*=[\t\n\f\r ]*["']?$/.exec(previous);
        if (event) events.push({ref, type: event[1], marker});
        previous = span.literal.text;
      }
      if (events.length) {
        const fragment = JSDOM.fragment(html);
        const controls = [...fragment.querySelectorAll('*')];
        for (const {ref, type, marker} of events) {
          const matches = controls.filter(control => control.getAttribute('@' + type) === marker);
          if (!matches.length) {
            // A lexical lookalike inside a normal attribute, text or comment
            // is not an event. A dropped duplicate event has no such location
            // and still fails the complete-attribute assertion below.
            if (controls.some(control => [...control.attributes].some(attribute =>
              !attribute.name.startsWith('@') && attribute.value.includes(marker)))) continue;
            const text = fragment.ownerDocument.createTreeWalker(fragment, 4 | 128);
            let node, inText = false;
            while ((node = text.nextNode())) if (node.nodeValue.includes(marker)) inText = true;
            if (inText) continue;
          }
          assert.equal(matches.length, 1, 'event binding is a complete attribute on one real control');
          assert.ok(ts.isPropertyAccessExpression(ref) && ref.expression.kind === ts.SyntaxKind.ThisKeyword,
            'event binding must be a stable method reference on this');
          const control = matches[0];
          let id = control.getAttribute('id') ?? '';
          for (const [token, expression] of expressions) id = id.replaceAll(token, expression);
          if (control.hasAttribute('id')) control.setAttribute('id', id);
          bindings.push({type, method: ref.name.text, position: ref.getStart(tree),
            tag: control.localName, id, markup: control.outerHTML});
        }
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(tree);
  bindings.sort((a, b) => a.position - b.position);
  const expected = [
    ['click', 'onChangeDownloadsPathClick_'], ['click', 'onClearAutoOpenFileTypesClick_'],
    ['click', 'onAegisRetryClick_'], ['change', 'onAegisParallelModeChange_'],
    ...Array.from({length: 4}, () => ['change', 'onAegisToggleChange_']),
    ['change', 'onAegisLimitModeChange_'], ['change', 'onAegisLimitChange_'],
  ];
  assert.equal(bindings.length, 10, 'all ten syntactic event bindings');
  assert.equal(new Set(bindings.map(b => b.method)).size, 7, 'all seven method targets');
  assert.deepEqual(bindings.map(b => [b.type, b.method]), expected, 'exact ordered event-to-method mapping');
  assert.deepEqual(bindings.map(b => [b.tag, b.id]), [
    ['controlled-button', 'changeDownloadsPath'], ['cr-button', 'resetAutoOpenFileTypes'],
    ['cr-button', ''], ['select', ''],
    ['cr-toggle', 'aegisReduceOnMetered'], ['cr-toggle', 'aegisReduceOnBattery'],
    ['cr-toggle', 'aegisTorrentDhtEnabled'], ['cr-toggle', 'aegisTorrentPexEnabled'],
    ['select', 'aegis${kind}Mode'], ['cr-input', 'aegisTorrent${kind}Limit'],
  ], 'each callback stays on its exact real control');
  return bindings;
}

export function assertDownloadDispatch(owner, control, event, calls) {
  assert.equal(calls.length, 1, 'exactly one callback');
  assert.equal(calls[0].owner, owner, 'Lit component receiver');
  assert.equal(calls[0].event, event, 'same actual event');
  assert.equal(calls[0].target, control, 'actual currentTarget');
  assert.equal(calls[0].value, control.value, 'actual control value');
}
