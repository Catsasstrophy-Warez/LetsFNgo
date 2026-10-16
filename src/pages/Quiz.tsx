import { useEffect, useMemo, useState } from 'react';
import { Cite } from '../components/Facts';
import { EMPTY_SCORE, loadScore, quizRound, recordAnswer, saveScore } from '../lib/quiz';

export default function Quiz() {
  const [seed, setSeed] = useState(() => Math.floor(Math.random() * 1e6));
  const qs = useMemo(() => quizRound(seed, 10), [seed]);
  const [i, setI] = useState(0);
  const [picked, setPicked] = useState<number | null>(null);
  const [round, setRound] = useState(0);
  const [score, setScore] = useState(loadScore);
  useEffect(() => { saveScore(score); }, [score]);
  const q = qs[i];
  const done = i >= qs.length;

  const answer = (k: number) => {
    if (picked !== null) return;
    setPicked(k);
    const ok = k === q.answer;
    if (ok) setRound((r) => r + 1);
    setScore((s) => recordAnswer(s, ok));
  };
  const next = () => { setPicked(null); setI(i + 1); };
  const restart = () => { setSeed(seed + 1); setI(0); setPicked(null); setRound(0); };

  return (
    <>
      <h1>GT500 Trivia</h1>
      <p className="lede">Questions are generated only from confirmed or reported facts in this app. The source is shown after each answer.</p>
      <div className="stats">
        <div className="stat"><div className="stat-v">{round}<small>/ {qs.length}</small></div><div className="stat-l">This round</div></div>
        <div className="stat"><div className="stat-v">{score.answered ? Math.round((score.correct / score.answered) * 100) : 0}<small>%</small></div><div className="stat-l">All-time ({score.correct}/{score.answered})</div></div>
        <div className="stat"><div className="stat-v">{score.streak}</div><div className="stat-l">Streak</div></div>
        <div className="stat"><div className="stat-v">{score.bestStreak}</div><div className="stat-l">Best streak</div></div>
      </div>
      {done ? (
        <section className="card hl">
          <h2>Round complete: {round} / {qs.length}</h2>
          <div className="btn-row"><button className="btn" onClick={restart}>New round</button>
            <button className="btn ghost" onClick={() => { if (confirm('Reset your quiz score?')) setScore({ ...EMPTY_SCORE }); }}>Reset score</button></div>
        </section>
      ) : (
        <section className="card" aria-labelledby="q-h">
          <p className="muted small">Question {i + 1} of {qs.length}</p>
          <h2 id="q-h">{q.prompt}</h2>
          <div className="choices" role="group" aria-label="Answers">
            {q.choices.map((c, k) => {
              const state = picked === null ? '' : k === q.answer ? 'right' : k === picked ? 'wrong' : '';
              return <button key={k} className={`choice ${state}`} onClick={() => answer(k)} aria-disabled={picked !== null} aria-pressed={picked === k}>{c}{state === 'right' && ' ✓'}{state === 'wrong' && ' ✗'}</button>;
            })}
          </div>
          {picked !== null && (
            <div role="status">
              <p className={picked === q.answer ? 'ok-t' : 'err'}><strong>{picked === q.answer ? 'Correct.' : 'Not quite.'}</strong> {q.fact}</p>
              <p>Source: <Cite c={q.confidence} url={q.source} /></p>
              <button className="btn" onClick={next}>{i + 1 < qs.length ? 'Next question' : 'See result'}</button>
            </div>
          )}
        </section>
      )}
    </>
  );
}
