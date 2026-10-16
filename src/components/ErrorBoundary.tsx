import { Component, type ReactNode } from 'react';
import { resetAll } from '../lib/backup';
import { SettingsContext } from './SettingsContext';
import { translate, type MsgKey } from '../lib/i18n';

/** Catches render errors (e.g. corrupt stored data) and offers a way out instead of a blank page. */
export class ErrorBoundary extends Component<{ children: ReactNode; resetKey?: string }, { error: Error | null; key?: string }> {
  static contextType = SettingsContext;
  declare context: React.ContextType<typeof SettingsContext>;
  state: { error: Error | null; key?: string } = { error: null, key: this.props.resetKey };
  static getDerivedStateFromError(error: Error) { return { error }; }
  static getDerivedStateFromProps(p: { resetKey?: string }, s: { error: Error | null; key?: string }) {
    return p.resetKey !== s.key ? { error: null, key: p.resetKey } : null;
  }
  render() {
    if (!this.state.error) return this.props.children;
    const t = (k: MsgKey) => translate(this.context?.settings?.lang ?? 'en', k);
    return (
      <section className="card warn" role="alert">
        <h1>{t('err.title')}</h1>
        <p>{t('err.text')}</p>
        <p className="muted small mono wrap">{this.state.error.message}</p>
        <div className="btn-row">
          <button className="btn ghost" onClick={() => this.setState({ error: null })}>{t('err.retry')}</button>
          <button className="btn" onClick={() => { if (confirm(t('err.confirm'))) { resetAll(); location.reload(); } }}>{t('err.reset')}</button>
        </div>
      </section>
    );
  }
}
