'use strict';

const fs = require('node:fs');
const path = require('node:path');

// Keep Obsidian notes intact while publishing their shared image attachments.
function normalizeImages(content, imageDir) {
  let fence = null;
  return content.split('\n').map(line => {
    const marker = line.match(/^\s{0,3}(`{3,}|~{3,})/);
    if (marker) {
      if (!fence) fence = marker[1];
      else if (marker[1][0] === fence[0] && marker[1].length >= fence.length) fence = null;
      return line;
    }
    if (fence) return line;

    // Inline code examples are also preserved.
    return line.split(/(`+[^`]*`+)/g).map(part => {
      if (part.startsWith('`')) return part;
      return part.replace(/!\[\[([^\]\n]+\.(?:png|jpe?g|gif|webp|svg))(?:\|([^\]\n]+))?\]\]/gi,
        (match, target, size) => {
          const filename = path.basename(target);
          if (!fs.existsSync(path.join(imageDir, filename))) return match;
          const url = '/images/' + encodeURIComponent(filename);
          if (size && /^\d+(?:x\d+)?$/.test(size)) {
            const [width, height] = size.split('x');
            const alt = filename.replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
            return `<img src="${url}" alt="${alt}" width="${width}"${height ? ` height="${height}"` : ''} loading="lazy">`;
          }
          return `![${size || ''}](${url})`;
        });
    }).join('');
  }).join('\n');
}

function normalizeRenderedPaths(content) {
  // Source-relative paths would otherwise resolve under /year/month/day/post/.
  return content.replace(/(<img\b[^>]*\bsrc=["'])\/?(?:\.\.\/)+images\//gi, '$1/images/');
}

hexo.extend.filter.register('before_post_render', data => {
  if (typeof data.content === 'string') {
    data.content = normalizeImages(data.content, path.join(hexo.source_dir, 'images'));
  }
  return data;
});

hexo.extend.filter.register('after_post_render', data => {
  for (const field of ['content', 'excerpt', 'more']) {
    if (typeof data[field] === 'string') data[field] = normalizeRenderedPaths(data[field]);
  }
  return data;
});

module.exports = { normalizeImages, normalizeRenderedPaths };
