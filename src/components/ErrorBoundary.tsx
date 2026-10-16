import { Component, type ReactNode } from 'react';
import { resetAll } from '../lib/backup';

/** Catches render errors (e.g. corrupt stored data) and offers a way out instead of a blank page. */
export class ErrorBoundary extends Component<{ children: ReactNode; resetKey?: string }, { error: Error | null; key?: string }> {
  state: { error: Error | null; key?: string } = { error: null, key: this.props.resetKey };
  static getDerivedStateFromError(error: Error) { return { error }; }
  static getDerivedStateFromProps(p: { resetKey?: string }, s: { error: Error | null; key?: string }) {
    return p.resetKey !== s.key ? { error: null, key: p.resetKey } : null;
  }
  render() {
    if (!this.state.error) return this.props.children;
    return (
      <section className="card warn" role="alert">
        <h1>Something went wrong</h1>
        <p>This page could not be shown. Data saved on this device may be damaged.</p>
        <p className="muted small mono wrap">{this.state.error.message}</p>
        <div className="btn-row">
          <button className="btn ghost" onClick={() => this.setState({ error: null })}>Try again</button>
          <button className="btn" onClick={() => { if (confirm('Erase all GT500 Companion data on this device? Export a backup from Settings first if you can.')) { resetAll(); location.reload(); } }}>Reset this data</button>
        </div>
      </section>
    );
  }
}
