import { registerLang } from '../src/lib/i18n';
import { es } from '../src/lib/i18n-es';

// The Spanish dictionary is a lazily loaded chunk in the app; tests install it up front.
registerLang('es', es);
