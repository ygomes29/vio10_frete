// Stub do pacote `server-only` para o vitest. No build do Next o compiler troca este
// import por um no-op server-side; no vitest (node puro) apontamos o alias para este
// arquivo vazio para permitir carregar módulos que o declaram.
export {};