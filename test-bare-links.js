// test-bare-links.js
// Render a test input with www.example.com and example.com using markdown.mjs
// Usage: cd /opt/csi/csi-spl-wt/m-539/csi-spl-wui && node test-bare-links.js

import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const markdownPath = join(__dirname, 'csi-spl-wui/src/utils/markdown.mjs');

const { markdownTree, markdownToHtml } = await import(markdownPath);

const testInput = `
This is a test message with bare links:
- www.example.com
- example.com
- https://www.example.com
- http://example.com
`;

const tree = markdownTree(testInput);
console.log("Rendered tree:", JSON.stringify(tree, null, 2));

const html = markdownToHtml(testInput, 'https://app.example.com');
console.log("\nRendered HTML:", html);

// Extract text content for comparison
function extractText(node) {
  if (typeof node === 'string') return node;
  if (Array.isArray(node)) return node.map(extractText).join('');
  if (node.children) return extractText(node.children);
  return '';
}

const textContent = extractText(tree);
console.log("\nText content:", textContent);

// Check if bare links are rendered as links or text
const hasBareLinkAsLink = html.includes('<a href="http://www.example.com"');
const hasExampleAsLink = html.includes('<a href="http://example.com"');

console.log("\nBare links rendered as links?");
console.log(`- www.example.com: ${hasBareLinkAsLink ? 'YES (link)' : 'NO (text)'}`);
console.log(`- example.com: ${hasExampleAsLink ? 'YES (link)' : 'NO (text)'}`);