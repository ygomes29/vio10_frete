/** @type {import('postcss-load-config').Config} */
// Tailwind CSS v4 (ADR-023 Fase 1). Doc Next 16: app/getting-started/11-css.md.
const config = {
  plugins: {
    "@tailwindcss/postcss": {},
  },
};

export default config;