/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        darkBg: "#0B0E14",
        darkPanel: "#151B26",
        neonGreen: "#00E676",
        neonRed: "#FF1744",
        goldPOC: "#FFD600",
      }
    },
  },
  plugins: [],
}
