// Extract named entities from entities/dist/generated/encode-html.js
// and print them as a JSON array of strings.

const fs = require('fs');
const path = require('path');

// Read the encode-html.js file
const encodeHtmlPath = path.join(__dirname, '../csi-spl-wui/node_modules/entities/dist/generated/encode-html.js');
const encodeHtmlContent = fs.readFileSync(encodeHtmlPath, 'utf8');

// Extract the named entities string
const namedEntitiesString = encodeHtmlContent.match(/export default "([^"]+)"/)[1];

// Split the string into individual named entities
const namedEntities = [];
let current = '';
for (const char of namedEntitiesString) {
  if (char === ';') {
    namedEntities.push(`&${current};`);
    current = '';
  } else {
    current += char;
  }
}

// Print as JSON array
console.log(JSON.stringify(namedEntities, null, 2));