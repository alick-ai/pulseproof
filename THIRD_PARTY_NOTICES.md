# Third-party runtime components

PulseProof's routing engine uses only the Ruby standard library.

The optional local replay interface uses these open-source packages:

| Package | Installed version | License |
|---|---:|---|
| React | 19.2.8 | MIT |
| React DOM | 19.2.8 | MIT |
| Vite | 8.2.2 | MIT |
| `@vitejs/plugin-react` | 6.1.1 | MIT |
| Lucide React | 1.40.0 | ISC |
| ESLint | 10.9.1 | MIT |
| `@eslint/js` | 10.0.1 | MIT |
| `eslint-plugin-react-hooks` | 7.1.1 | MIT |
| `eslint-plugin-react-refresh` | 0.5.6 | MIT |
| globals | 17.12.0 | MIT |

The dependency lockfile is committed for reproducibility. No hosted decision service, proprietary optimizer or database is used at runtime.
