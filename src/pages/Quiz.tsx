import { useEffect, useMemo, useState } from 'react';
import { Cite } from '../components/Facts';
import { useT } from '../components/SettingsContext';

import { EMPTY_SCORE, loadScore, quizRound, recordAnswer, saveScore } from '../lib/quiz';

export default function Quiz() {
  const t = useT();
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
      <h1>{t('quiz.title')}</h1>
      <p className="lede">{t('quiz.lede')}</p>
      <div className="stats">
        <div className="stat"><div className="stat-v">{round}<small>/ {qs.length}</small></div><div className="stat-l">{t('quiz.round')}</div></div>
        <div className="stat"><div className="stat-v">{score.answered ? Math.round((score.correct / score.answered) * 100) : 0}<small>%</small></div><div className="stat-l">{t('quiz.allTime', { c: score.correct, a: score.answered })}</div></div>
        <div className="stat"><div className="stat-v">{score.streak}</div><div className="stat-l">{t('quiz.streak')}</div></div>
        <div className="stat"><div className="stat-v">{score.bestStreak}</div><div className="stat-l">{t('quiz.best')}</div></div>
      </div>
      {done ? (
        <section className="card hl">
          <h2>{t('quiz.complete', { r: round, n: qs.length })}</h2>
          <div className="btn-row"><button className="btn" onClick={restart}>{t('quiz.new')}</button>
            <button className="btn ghost" onClick={() => { if (confirm(t('quiz.resetConfirm'))) setScore({ ...EMPTY_SCORE }); }}>{t('quiz.reset')}</button></div>
        </section>
      ) : (
        <section className="card" aria-labelledby="q-h">
          <p className="muted small">{t('quiz.q', { i: i + 1, n: qs.length })}</p>
          <h2 id="q-h">{q.prompt}</h2>
          <div className="choices" role="group" aria-label={t('quiz.answers')}>
            {q.choices.map((c, k) => {
              const state = picked === null ? '' : k === q.answer ? 'right' : k === picked ? 'wrong' : '';
              return <button key={k} className={`choice ${state}`} onClick={() => answer(k)} aria-disabled={picked !== null} aria-pressed={picked === k}>{c}{state === 'right' && ' ✓'}{state === 'wrong' && ' ✗'}</button>;
            })}
          </div>
          {picked !== null && (
            <div role="status">
              <p className={picked === q.answer ? 'ok-t' : 'err'}><strong>{picked === q.answer ? t('quiz.correct') : t('quiz.wrong')}</strong> {q.fact}</p>
              <p>{t('quiz.source')} <Cite c={q.confidence} url={q.source} /></p>
              <button className="btn" onClick={next}>{i + 1 < qs.length ? t('quiz.next') : t('quiz.result')}</button>
            </div>
          )}
        </section>
      )}
    </>
  );
}
