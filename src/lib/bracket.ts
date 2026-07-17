// MK tournament bracket: generation, result propagation, player swaps.
//
// Fixed downstream structure:
//   R2: 4 groups × 4 (top 2 each → 8)   R3: 2 groups × 4 (top 2 → 4)   Final: 4
//   shortFinal: R2 → Final directly, only the winner of each R2 group qualifies
// R1 adapts so that exactly 16 players reach R2; N > 32 adds an R0 layer.

import { supabase } from './supabase';
import { shuffle } from './utils';

export type Match = {
  id: string;
  bracket: 'winners' | 'losers' | 'final';
  round: number;
  match_num: number;
  players: (string | null)[];
  results: Record<string, number>;
  status: 'pending' | 'completed';
  advance_to: string | null;
  drop_to: string | null;
};

function makeMatch(partial: Partial<Match> & Pick<Match, 'id' | 'bracket' | 'round' | 'match_num'>): Match {
  return { players: [], results: {}, status: 'pending', advance_to: null, drop_to: null, ...partial };
}

export function generateBracket(players: string[], shortFinal = false): Match[] {
  const N = players.length;
  if (N < 4) return [];
  const shuffled = shuffle(players);
  const matches: Match[] = [];
  let r2Auto: string[] = []; // players qualified straight into R2

  if (N > 32) {
    // R0 reduces to 32 (groups of 4, top 2 advance), then 8 empty R1 groups
    const numG0 = Math.ceil((N - 32) / 2);
    const playersInR0 = numG0 * 4;
    r2Auto = shuffled.slice(0, N - playersInR0);
    const r0Players = shuffled.slice(N - playersInR0);
    for (let i = 0; i < numG0; i++) {
      matches.push(makeMatch({
        id: `W-0-${i + 1}`, bracket: 'winners', round: 0, match_num: i + 1,
        players: r0Players.slice(i * 4, i * 4 + 4), advance_to: 'W-1',
      }));
    }
    for (let i = 0; i < 8; i++) {
      matches.push(makeMatch({
        id: `W-1-${i + 1}`, bracket: 'winners', round: 1, match_num: i + 1,
        players: new Array(4).fill(null), advance_to: 'W-2',
      }));
    }
  } else if (N > 16) {
    // R1 eliminates the surplus: groups of 4 drop 2, one group of 3 drops 1
    const extras = N - 16;
    const numG4 = Math.floor(extras / 2);
    const numG3 = extras % 2;
    const playersInR1 = numG4 * 4 + numG3 * 3;
    r2Auto = shuffled.slice(0, N - playersInR1);
    const r1Players = shuffled.slice(N - playersInR1);
    let pidx = 0;
    for (let i = 0; i < numG4 + numG3; i++) {
      const size = i < numG4 ? 4 : 3;
      matches.push(makeMatch({
        id: `W-1-${i + 1}`, bracket: 'winners', round: 1, match_num: i + 1,
        players: r1Players.slice(pidx, pidx + size), advance_to: 'W-2',
      }));
      pidx += size;
    }
  } else {
    r2Auto = shuffled; // N ≤ 16: no R1
  }

  // R2: auto-qualifiers split evenly between upper half (W-2-1/2 → W-3-1)
  // and lower half (W-2-3/4 → W-3-2); R1 advancers fill the rest on propagation
  const halfIdx = Math.ceil(r2Auto.length / 2);
  const autoPerGroup = [0, 0, 0, 0];
  r2Auto.slice(0, halfIdx).forEach((_, i) => { autoPerGroup[i % 2]++; });
  r2Auto.slice(halfIdx).forEach((_, i) => { autoPerGroup[2 + i % 2]++; });

  let autoIdx = 0;
  for (let i = 0; i < 4; i++) {
    const numAuto = autoPerGroup[i];
    matches.push(makeMatch({
      id: `W-2-${i + 1}`, bracket: 'winners', round: 2, match_num: i + 1,
      players: [...r2Auto.slice(autoIdx, autoIdx + numAuto), ...new Array(4 - numAuto).fill(null)],
      advance_to: shortFinal ? 'F' : 'W-3',
    }));
    autoIdx += numAuto;
  }

  if (!shortFinal) {
    for (let i = 0; i < 2; i++) {
      matches.push(makeMatch({
        id: `W-3-${i + 1}`, bracket: 'winners', round: 3, match_num: i + 1,
        players: new Array(4).fill(null), advance_to: 'F',
      }));
    }
  }

  matches.push(makeMatch({
    id: 'F', bracket: 'final', round: 99, match_num: 1, players: new Array(4).fill(null),
  }));

  return matches;
}

// Place a player into the first free slot across matchIds (in order).
// Uses the Postgres function mk_fill_player (row lock) so two referees
// validating pools simultaneously cannot clobber each other.
export async function fillPlayer(matchIds: string[], player: string): Promise<void> {
  const { error } = await supabase.rpc('mk_fill_player', { match_ids: matchIds, player });
  if (error) alert(`Erreur placement de ${player} : ` + error.message);
}

export async function fillPlayers(matchIds: string[], players: string[]): Promise<void> {
  for (const player of players) await fillPlayer(matchIds, player);
}

// Propagate a completed match's results to the next round.
// Half-bracket seeding (R1→R2 and R2→R3): odd group → 1st upper / 2nd lower,
// even group → the opposite, so groupmates can only meet again in the Final.
export async function propagateMatchResults(
  match: Match,
  results: Record<string, number>,
  allMatches: Match[],
  format: 'standard' | 'short',
): Promise<void> {
  const sorted = Object.entries(results).sort(([, a], [, b]) => a - b);

  if (match.bracket === 'final') {
    await supabase.from('competition_config').upsert({ key: 'mk_phase', value: 'completed' }, { onConflict: 'key' });
    return;
  }

  const roundMatches = (round: number) => allMatches
    .filter(m => m.bracket === 'winners' && m.round === round)
    .sort((a, b) => a.match_num - b.match_num);

  const seedHalves = async (targets: Match[], splitAt: number) => {
    const first = sorted.find(([, p]) => p === 1)?.[0];
    const second = sorted.find(([, p]) => p === 2)?.[0];
    const upper = targets.filter(m => m.match_num <= splitAt).map(m => m.id);
    const lower = targets.filter(m => m.match_num > splitAt).map(m => m.id);
    const isOdd = match.match_num % 2 === 1;
    if (first) await fillPlayer(isOdd ? upper : lower, first);
    if (second) await fillPlayer(isOdd ? lower : upper, second);
  };

  if (match.round === 1 && match.bracket === 'winners') {
    await seedHalves(roundMatches(2), 2);
    return;
  }

  if (match.round === 2 && match.bracket === 'winners') {
    if (format === 'short') {
      const winner = sorted.filter(([, p]) => p <= 1).map(([u]) => u);
      await fillPlayers(['F'], winner);
    } else {
      const r3 = roundMatches(3);
      await seedHalves(r3, Math.ceil(r3.length / 2));
    }
    return;
  }

  const advancers = sorted.filter(([, p]) => p <= 2).map(([u]) => u);

  if (match.round === 3 && match.bracket === 'winners') {
    await fillPlayers(['F'], advancers);
    return;
  }

  // Generic fallback (R0, future loser bracket)
  if (match.advance_to === 'F') {
    await fillPlayers(['F'], advancers);
  } else {
    const { data } = await supabase.from('mk_matches')
      .select('id, players, match_num')
      .eq('bracket', 'winners')
      .eq('round', match.round + 1)
      .order('match_num');
    await fillPlayers((data || []).map(m => m.id), advancers);
  }
}

// Swap two players between groups — or, if the source match already has
// results, just rename p1 → p2 in that match (transferring the score).
export async function swapBracketPlayers(
  p1: string, matchId1: string,
  p2: string, matchId2: string,
  hasResults = false,
): Promise<void> {
  if (hasResults) {
    const { data } = await supabase.from('mk_matches').select('players, results').eq('id', matchId1).single();
    if (!data) return;
    const arr1 = [...(data.players || [])];
    const idx1 = arr1.indexOf(p1);
    if (idx1 === -1) { alert('Erreur : joueur introuvable.'); return; }
    arr1[idx1] = p2;
    const results = { ...(data.results || {}) };
    if (p1 in results) { results[p2] = results[p1]; delete results[p1]; }
    await supabase.from('mk_matches').update({ players: arr1, results }).eq('id', matchId1);
    return;
  }
  const [r1, r2] = await Promise.all([
    supabase.from('mk_matches').select('players').eq('id', matchId1).single(),
    supabase.from('mk_matches').select('players').eq('id', matchId2).single(),
  ]);
  const arr1 = [...(r1.data?.players || [])];
  const arr2 = matchId1 === matchId2 ? arr1 : [...(r2.data?.players || [])];
  const idx1 = arr1.indexOf(p1);
  const idx2 = arr2.indexOf(p2);
  if (idx1 === -1 || idx2 === -1) { alert('Erreur : joueur introuvable.'); return; }
  arr1[idx1] = p2;
  arr2[idx2] = p1;
  if (matchId1 === matchId2) {
    await supabase.from('mk_matches').update({ players: arr1 }).eq('id', matchId1);
  } else {
    await Promise.all([
      supabase.from('mk_matches').update({ players: arr1 }).eq('id', matchId1),
      supabase.from('mk_matches').update({ players: arr2 }).eq('id', matchId2),
    ]);
  }
}
