import { tr } from '../lib/i18n';
import { useId } from 'react';

/** Generic fastback silhouette drawn in SVG — not a trademark, logo or photo. */
export function CarArt({ body = '#c8102e', stripe = '#f4f4f4', stripes = true, className = '', label }: { body?: string; stripe?: string; stripes?: boolean; className?: string; label?: string }) {
  const clip = `carBody-${useId().replace(/:/g, '')}`;
  return (
    <svg className={`car-art ${className}`} viewBox="0 0 400 140" role="img" aria-label={label ?? tr('car.art')}>
      <defs>
        <clipPath id={clip}><path d="M20 98 C22 80 40 74 70 70 L120 64 C150 40 190 30 236 32 C270 34 300 50 330 66 L372 74 C388 78 392 88 390 100 L386 108 L20 108 Z" /></clipPath>
      </defs>
      <ellipse cx="205" cy="116" rx="190" ry="8" fill="rgba(0,0,0,.35)" />
      <g clipPath={`url(#${clip})`}>
        <rect x="0" y="0" width="400" height="140" fill={body} />
        {stripes && <>
          <rect x="0" y="62" width="400" height="7" fill={stripe} opacity=".9" />
          <rect x="0" y="74" width="400" height="7" fill={stripe} opacity=".9" />
        </>}
      </g>
      <path d="M136 64 C160 44 192 38 230 38 C258 39 282 50 304 64 Z" fill="rgba(10,12,16,.85)" />
      <path d="M214 39 L218 64" stroke={body} strokeWidth="4" />
      <circle cx="104" cy="106" r="22" fill="#111" /><circle cx="104" cy="106" r="13" fill="#555" />
      <circle cx="316" cy="106" r="22" fill="#111" /><circle cx="316" cy="106" r="13" fill="#555" />
      <rect x="372" y="80" width="14" height="6" rx="2" fill="#ffd9a0" />
      <rect x="22" y="84" width="10" height="6" rx="2" fill="#ff3b30" />
    </svg>
  );
}
