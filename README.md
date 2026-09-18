# AQTools
Air Quality Processing Tools

## Editing and publishing

Edit pages under `src/`, not the `.html` files at the repo root - the root
copies are generated output (minified) and are what GitHub Pages actually
serves. After editing, run:

```
npm install
npm run build
```

then commit and push both `src/` and the regenerated root files together.
