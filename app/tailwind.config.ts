import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        navy: {
          900: "#0a0a2e",
          800: "#0f0f3d",
          700: "#16164d",
          600: "#1e1e5e",
        },
        teal: {
          400: "#00d4aa",
          500: "#00b894",
          600: "#009a7a",
        },
        amber: {
          400: "#e8a838",
          500: "#d4912a",
        },
        pixel: {
          blue: "#1a1a4e",
          cyan: "#00e5cc",
          orange: "#e8a030",
          green: "#00ff88",
          red: "#ff4466",
          darkblue: "#08082a",
        },
      },
      fontFamily: {
        pixel: ['"Press Start 2P"', "monospace"],
        mono: ['"IBM Plex Mono"', "monospace"],
      },
      animation: {
        marquee: "marquee 20s linear infinite",
      },
      keyframes: {
        marquee: {
          "0%": { transform: "translateX(0%)" },
          "100%": { transform: "translateX(-50%)" },
        },
      },
    },
  },
  plugins: [],
};

export default config;
