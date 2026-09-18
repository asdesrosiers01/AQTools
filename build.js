// Minifies every page in src/ and writes the published copy to the repo
// root, which is what GitHub Pages actually serves. Edit files in src/,
// then run `npm run build` before committing.
const fs = require("fs");
const path = require("path");
const { minify } = require("html-minifier-terser");

const SRC = path.join(__dirname, "src");
const OUT = __dirname;

const OPTS = {
  collapseWhitespace: true,
  conservativeCollapse: true,
  removeComments: true,
  minifyJS: true,
  minifyCSS: true,
  removeAttributeQuotes: false,
  keepClosingSlash: true,
};

async function run() {
  const files = fs.readdirSync(SRC).filter(f => f.endsWith(".html"));
  let okCount = 0;
  for (const f of files) {
    const inPath = path.join(SRC, f);
    const outPath = path.join(OUT, f);
    const src = fs.readFileSync(inPath, "utf8");
    try {
      const out = await minify(src, OPTS);
      fs.writeFileSync(outPath, out, "utf8");
      const pct = (100 * (1 - out.length / src.length)).toFixed(1);
      console.log(`${f}: ${src.length} -> ${out.length} bytes (-${pct}%)`);
      okCount++;
    } catch (e) {
      console.error(`FAILED on ${f}: ${e.message}`);
      process.exitCode = 1;
    }
  }
  console.log(`Built ${okCount} / ${files.length} pages.`);
}

run();
