# Software catalog maintenance

The software list lives in `catalog-data.js`. After adding or editing an entry, run `node tools/generate-software-catalog.js` from the repository root. The generator updates only the marked card, filter, and count blocks in `source/software/index.html`; it does not build Hexo. A download-count hook is generated only for the explicit `paper2zh` statistics field.
