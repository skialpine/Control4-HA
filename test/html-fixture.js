const fs = require("node:fs");
const path = require("node:path");

module.exports = function elementLookup(create, ...sources) {
  const ids = new Set();
  for (const source of sources) {
    const html = fs.readFileSync(path.resolve(__dirname, "..", source), "utf8");
    for (const [, id] of html.matchAll(/\sid=["']([^"']+)["']/g)) ids.add(id);
  }
  const elements = new Map();
  return (id) => {
    if (!ids.has(id)) return null;
    if (!elements.has(id)) elements.set(id, create());
    return elements.get(id);
  };
};
