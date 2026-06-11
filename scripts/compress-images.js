// Compresse les photos de galerie vers public/images/
// Usage : node scripts/compress-images.js
// À relancer chaque fois que tu ajoutes de nouvelles photos dans src/assets/images/

import sharp from 'sharp';
import fs from 'node:fs';
import path from 'node:path';

const SRC = 'src/assets/images';
const DEST = 'public/images';
const MAX_WIDTH = 1200;
const QUALITY = 78;

// Fichiers à garder dans src/assets/ (utilisés par le composant <Image> d'Astro)
const EXCLUDE = ['pano_20210522_111202-min.jpg', 'mario.png'];

fs.mkdirSync(DEST, { recursive: true });

const files = fs.readdirSync(SRC).filter(f =>
  /\.(jpg|jpeg|png)$/i.test(f) && !EXCLUDE.includes(f)
);

console.log(`Compression de ${files.length} photos vers ${DEST}/...\n`);

let totalBefore = 0;
let totalAfter = 0;

for (const file of files) {
  const srcPath = path.join(SRC, file);
  const destName = file.replace(/\.(jpeg|png)$/i, '.jpg');
  const destPath = path.join(DEST, destName);

  const sizeBefore = fs.statSync(srcPath).size;
  totalBefore += sizeBefore;

  await sharp(srcPath)
    .resize({ width: MAX_WIDTH, withoutEnlargement: true })
    .jpeg({ quality: QUALITY, mozjpeg: true })
    .toFile(destPath);

  const sizeAfter = fs.statSync(destPath).size;
  totalAfter += sizeAfter;

  const ratio = Math.round((1 - sizeAfter / sizeBefore) * 100);
  console.log(`  ${file} : ${(sizeBefore/1024).toFixed(0)}kB → ${(sizeAfter/1024).toFixed(0)}kB (-${ratio}%)`);
}

console.log(`\nTotal : ${(totalBefore/1024/1024).toFixed(1)}MB → ${(totalAfter/1024/1024).toFixed(1)}MB`);
