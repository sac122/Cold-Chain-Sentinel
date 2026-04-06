/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{js,jsx,ts,tsx}"],
  theme: {
    extend: {
      colors: {
        brand: "#3B82F6",
      },
      animation: {
        "pulse-fast": "pulse 0.8s cubic-bezier(0.4,0,0.6,1) infinite",
      },
    },
  },
  plugins: [],
};
