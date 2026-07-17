// Ranking & lottery math shared by the results and admin pages.
// All ranks are 1-indexed; ties are handled through mid-ranks.

export type RawRanking = { username: string; rank: number };

export type RankingCtx = {
  genderMap: Record<string, string | null>; // username → 'F' | 'M' | null
  atelierSet: Set<string>;                  // usernames with the workshop ×2 bonus
};

export function median(arr: number[]): number {
  if (!arr.length) return 0;
  const sorted = [...arr].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

export function mean(arr: number[]): number {
  return arr.length ? arr.reduce((s, v) => s + v, 0) / arr.length : 0;
}

// Tie-aware positions: ranks [10, 10, 12] → pos 1, 1, 3
export function withTiePos<T>(sorted: T[], keyFn: (item: T) => unknown): (T & { pos: number })[] {
  let pos = 1;
  return sorted.map((item, i, arr) => {
    if (!(i > 0 && keyFn(item) === keyFn(arr[i - 1]))) pos = i + 1;
    return { ...item, pos };
  });
}

// Ties → mid-ranks: two tied at pos 2 → both rank 2.5
export function toMidRanks(items: RawRanking[]): RawRanking[] {
  if (!items.length) return [];
  const sorted = [...items].sort((a, b) => a.rank - b.rank);
  const out: RawRanking[] = [];
  let i = 0;
  while (i < sorted.length) {
    let j = i + 1;
    while (j < sorted.length && sorted[j].rank === sorted[i].rank) j++;
    const mid = (i + 1 + j) / 2; // average of 1-indexed positions i+1..j
    for (let k = i; k < j; k++) out.push({ ...sorted[k], rank: mid });
    i = j;
  }
  return out;
}

// Lottery points (GSheets formula, traversed last→first):
// last: 1pt · second-to-last: 2× last · others: sum of all below · ties: same as next
export function computeLotteryPoints(sortedItems: RawRanking[]): number[] {
  const n = sortedItems.length;
  const pts = new Array(n).fill(0);
  for (let i = n - 1; i >= 0; i--) {
    if (i === n - 1) pts[i] = 1;
    else if (sortedItems[i].rank === sortedItems[i + 1].rank) pts[i] = pts[i + 1];
    else if (i === n - 2) pts[i] = pts[i + 1] * 2;
    else pts[i] = pts.slice(i + 1).reduce((s: number, p: number) => s + p, 0);
  }
  return pts;
}

// Shared pipeline: mid-ranked list → per-person lottery probability (%)
// Applies the workshop ×2 bonus individually (not to tied partners).
export function lotteryProbs(midRanked: RawRanking[], atelierSet: Set<string>) {
  const basePts = computeLotteryPoints(midRanked);
  const pts = basePts.map((p, i) => atelierSet.has(midRanked[i].username) ? p * 2 : p);
  const total = pts.reduce((s, p) => s + p, 0);
  return midRanked.map((r, i) => ({ username: r.username, rank: r.rank, prob: pts[i] / total * 100 }));
}

// Gender correction ("la magie"):
// Δ = avg(median diff, mean diff) in percentile space (F − M)
// Δ > 0 → F disadvantaged ; Δ < 0 → M disadvantaged
// boost = |Δ| × min(2·n, N) where n = size of the disadvantaged subgroup
// adjustedRank_disadvantaged = rank − boost
export function applyGenderCorrection(
  rankings: RawRanking[],
  genderMap: RankingCtx['genderMap'],
): { username: string; trueRank: number }[] {
  const identity = () => rankings.map(r => ({ username: r.username, trueRank: r.rank }));
  if (rankings.length < 2) return identity();
  const total = rankings.length;
  const withG = rankings.map(r => ({ ...r, gender: genderMap[r.username] || null, pct: r.rank / total }));
  const fPcts = withG.filter(r => r.gender === 'F').map(r => r.pct);
  const mPcts = withG.filter(r => r.gender === 'M').map(r => r.pct);
  if (!fPcts.length || !mPcts.length) return identity();
  const delta = ((median(fPcts) - median(mPcts)) + (mean(fPcts) - mean(mPcts))) / 2;
  const disadvantaged = delta >= 0 ? 'F' : 'M';
  const n = delta >= 0 ? fPcts.length : mPcts.length;
  const boost = Math.abs(delta) * Math.min(2 * n, total);
  return withG.map(r => ({
    username: r.username,
    trueRank: r.gender === disadvantaged ? r.rank - boost : r.rank,
  }));
}

// Full adjustment: mid-ranks → gender correction → re-sort → lottery probs
//   rawAdj   = rank right after the gender boost (before re-sorting)
//   trueRank = re-sorted mid-rank used for the probability
export function computeAdjusted(
  rawRankings: RawRanking[],
  { genderMap, atelierSet }: RankingCtx,
  applyGender = true,
) {
  if (!rawRankings.length) return [];
  const midRanked = toMidRanks(rawRankings);
  const corrected = applyGender
    ? applyGenderCorrection(midRanked, genderMap)
    : midRanked.map(r => ({ username: r.username, trueRank: r.rank }));
  const rawAdjMap = Object.fromEntries(corrected.map(r => [r.username, r.trueRank]));
  const sortedMid = toMidRanks(corrected.map(r => ({ username: r.username, rank: r.trueRank })));
  return lotteryProbs(sortedMid, atelierSet).map(p => ({
    username: p.username,
    rawAdj: rawAdjMap[p.username],
    trueRank: p.rank,
    prob: p.prob.toFixed(3),
  }));
}

// Combined ranking across events, restricted to participants present in all of them.
// normalized_rank = adjustedRank × N_combined / N_event, averaged across events.
export function computeCombined(
  eventRankings: RawRanking[][],
  applyGenderArr: boolean[] | null,
  ctx: RankingCtx,
) {
  const sets = eventRankings.map(e => new Set(e.map(r => r.username)));
  const common = [...sets[0]].filter(u => sets.every(s => s.has(u)));
  if (common.length < 2) return [];
  const nCombined = common.length;

  const normalizedPerEvent = eventRankings.map((eventRanks, idx) => {
    const nEvent = eventRanks.length;
    const applyGender = applyGenderArr ? applyGenderArr[idx] !== false : true;
    const adjusted = computeAdjusted(eventRanks, ctx, applyGender);
    const adjustedMap = Object.fromEntries(adjusted.map(r => [r.username, r.trueRank]));
    return common.map(username => ({
      username,
      norm: (adjustedMap[username] ?? nEvent) * (nCombined / nEvent),
    }));
  });

  const totals: Record<string, number> = {};
  normalizedPerEvent.forEach(ev => ev.forEach(r => { totals[r.username] = (totals[r.username] || 0) + r.norm; }));
  const nEvents = eventRankings.length;
  return Object.entries(totals)
    .map(([username, sum]) => ({ username, value: sum / nEvents }))
    .sort((a, b) => a.value - b.value)
    .map((r, i) => ({ participant_username: r.username, position: i + 1, rank_value: Math.round(r.value * 100) / 100 }));
}

// Bouldering scores: each problem's points are split among its toppers
export function computeBlocsScores(
  blocsList: { id: number; points: number }[],
  results: { participant_username: string; bloc_id: number; topped: boolean }[],
): Record<string, number> {
  const scores: Record<string, number> = {};
  blocsList.forEach(bloc => {
    const toppers = results.filter(r => r.bloc_id === bloc.id && r.topped);
    if (!toppers.length) return;
    const share = bloc.points / toppers.length;
    toppers.forEach(r => { scores[r.participant_username] = (scores[r.participant_username] ?? 0) + share; });
  });
  return scores;
}
