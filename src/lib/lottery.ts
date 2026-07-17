// Weighted lottery draw with cross-category conflict resolution.

export type Weighted = { username: string; prob: number };
export type Category = { key: string; probs: Weighted[] };

export function weightedRandom(probs: Weighted[]): string {
  const total = probs.reduce((s, p) => s + p.prob, 0);
  let r = Math.random() * total;
  for (const p of probs) { r -= p.prob; if (r <= 0) return p.username; }
  return probs[probs.length - 1].username;
}

// Draw all categories simultaneously. If someone wins several, they keep the
// one where their probability is highest (random tiebreak) and the others are
// re-drawn, excluding every current winner.
export function resolveGroupDraw(categories: Category[]): Record<string, string | null> {
  const current: Record<string, string | null> = {};
  for (const cat of categories) {
    current[cat.key] = cat.probs.length ? weightedRandom(cat.probs) : null;
  }
  for (let iter = 0; iter < 50; iter++) {
    const userCats: Record<string, string[]> = {};
    for (const [key, w] of Object.entries(current)) {
      if (w) { (userCats[w] ??= []).push(key); }
    }
    let hasConflict = false;
    for (const [user, cats] of Object.entries(userCats)) {
      if (cats.length < 2) continue;
      hasConflict = true;
      let bestCat = cats[0];
      let bestProb = categories.find(c => c.key === cats[0])?.probs.find(p => p.username === user)?.prob ?? 0;
      for (const k of cats.slice(1)) {
        const prob = categories.find(c => c.key === k)?.probs.find(p => p.username === user)?.prob ?? 0;
        if (prob > bestProb || (prob === bestProb && Math.random() < 0.5)) { bestProb = prob; bestCat = k; }
      }
      const excluded = new Set(Object.values(current).filter(Boolean));
      for (const k of cats) {
        if (k !== bestCat) {
          const cat = categories.find(c => c.key === k);
          const eligible = (cat?.probs ?? []).filter(p => !excluded.has(p.username));
          current[k] = eligible.length ? weightedRandom(eligible) : null;
        }
      }
      break; // restart conflict scan
    }
    if (!hasConflict) break;
  }
  return current;
}
